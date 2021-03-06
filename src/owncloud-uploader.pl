#!/usr/bin/perl -I /home/nemo/perl5/lib/perl5
# Automatic upload files to owncloud
# Copyright (C) 2015  Håvard Moen

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use local::lib;
use strict;

use Child;
use Config::Simple;
use File::Basename;
use HTTP::DAV;
use Log::Log4perl;
use Net::DBus;
use Net::DBus::Reactor;

my %seen_files;

my $data_dir = $ENV{'HOME'} . '/.local/share/owncloud-uploader';
mkdir($data_dir) unless -d $data_dir;
my $uploads_dir = "$data_dir/files_to_be_uploaded";
mkdir($uploads_dir) unless -d $uploads_dir;

my $config_dir = $ENV{'HOME'} . '/.config/owncloud-uploader';

Log::Log4perl::init("$config_dir/log4perl.conf");
my $logger = Log::Log4perl->get_logger('owncloud-uploader');

my $conf = new Config::Simple("$config_dir/config");
unless($conf) {
  $logger->error("Unable to open config file");
  exit 1;
};
foreach my $key (qw(owncloud_url owncloud_user owncloud_password)) {
  unless($conf->param($key)) {
    $logger->error("Missing config variable $key");
    exit 1;
  };
};
my $upload_on_cellular = 0;
$upload_on_cellular = 1 if $conf->param('upload_on_cellular') && $conf->param('upload_on_cellular') == 1;
my $upload_on_roaming = 0;
$upload_on_roaming = 1 if $conf->param('upload_on_roaming') && $conf->param('upload_on_roaming') == 1;
my $upload_on_wifi = 0;
$upload_on_wifi = 1 if $conf->param('upload_on_wifi') && $conf->param('upload_on_wifi') == 1;

# Read queue and upload files
my $uploader = Child->new(sub {
  my $num = 0;
  while(1) {
    if(opendir(my $dir, $uploads_dir)) {
      $num = 0;
      while(my $file = readdir($dir)) {
        next if $file =~ /^\.\.?$/;
        next unless -l "$uploads_dir/$file";
        $logger->info("Starting upload of $file");
        if(picture_upload("$uploads_dir/$file")) {
          unlink("$uploads_dir/$file") 
        } else {
          $num++;
        };
      };
      closedir($dir);
    } else {
      $logger->error("Unable to open $uploads_dir: $!");
      return 0;
    };
    return 1 if $num == 0;
    sleep(300);
  };
});
my $upload = $uploader->start;

my $bus = Net::DBus->find;
my $service = $bus->get_service("org.freedesktop.Tracker1");
my $object  = $service->get_object("/org/freedesktop/Tracker1/Resources",
				   "org.freedesktop.Tracker1.Resources");

$object->connect_to_signal("GraphUpdated", \&graph_updated_signal_handler);

my $reactor = Net::DBus::Reactor->main();

$logger->info("Starting owncloud-uploader");

$reactor->run();

# Handle tracker signal events
sub graph_updated_signal_handler {
  my $class = shift;
  my $deletes = shift;
  my $inserts = shift;
  # we only look for photos beeing added
  return unless $class eq 'http://www.tracker-project.org/temp/nmm#Photo';
  foreach my $insert (@$inserts) {
    my $ids = join(',', @$insert);
    my $result = $object->SparqlQuery("SELECT ?t { ?r nie:url ?t .FILTER (tracker:id(?r) IN ($ids)) }");
    unless($result->[0]->[0] =~ qr{^file://(.*)}) {
      $logger->debug("Not a file URI, skipping");
      next;
    };
    if(exists $seen_files{$1}) {
      $logger->debug("Already seen $1, skipping");
      next;
    };
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
      $atime,$mtime,$ctime,$blksize,$blocks)
    = stat($1);
    if(time - $mtime > 300) {
      $logger->debug("File $1 more than 5 minutes old, skipping");
      next;
    };
    $logger->info("Adding $1 to upload queue");
    $seen_files{$1} = time;
    add_picture_to_queue($1);
    if($upload->is_complete) {
      $upload = $uploader->start;
    };
    my $key;
    my $value;
    # purge out cache to save memory
    while(($key, $value) = each %seen_files) {
      delete $seen_files{$key} if (time() - $value) > 3600;
    };
  };
};

sub add_picture_to_queue {
  my $file = shift;
  my ($name,$path,$suffix) = fileparse($file);
  unless(-l "$uploads_dir/$name") { # resuming old upload
    unless(symlink($file, "$uploads_dir/$name")) {
      $logger->error("Unable to make symlink for $file");
    };
  };
};

# upload to owncloud
sub picture_upload {
  my $file = shift;
  return unless test_connectivity();

  my $dav = HTTP::DAV->new();
  my $url = $conf->param('owncloud_url');
  $dav->credentials(
    -user => $conf->param('owncloud_user'),
    -pass => $conf->param('owncloud_password'),
    -url => $url,
    -realm => 'ownCloud'
  );
  unless($dav->open(-url => $url)) {
    $logger->error("Unable to open $url: " . $dav->message);
    return 0;
  };

  my $upload_dir = $url;
  if($conf->param('owncloud_upload_dir')) {
    my $r;
    $upload_dir .= '/' . $conf->param('owncloud_upload_dir');
    unless($r = $dav->propfind(-url => $upload_dir, -depth => 0)) {
      $logger->debug("Upload dir $upload_dir does not exist, creating");
      unless($dav->mkcol(-url => $upload_dir)) {
        $logger->error("Unable to create upload directory: " . $dav->message);
        return 0;
      };
    };
  };

  $logger->debug("Uploading file $file");
  unless(-f $file) {
    $logger->warn("File $file does not exist");
    return 1;
  };
  my ($name,$path,$suffix) = fileparse($file, ".jpg");
  my $upload_name = $name;
  my $upload_dest = $upload_dir;
  if($conf->param('upload_zeros_to_add')) {
    if($upload_name =~ /^(\d+)_(\d+)$/) {
      $upload_name = $1 . '_' . '0' x $conf->param('upload_zeros_to_add') . $2;
    };
  };
  if($conf->param('upload_prefix')) {
    $upload_name = $conf->param('upload_prefix') . $upload_name;
  };
  if($conf->param('upload_suffix')) {
    $upload_name = $upload_name . $conf->param('upload_suffix');
  };
  $upload_name = $upload_name . $suffix;
  $logger->debug("uploading $file to $upload_dir/$upload_name");
  if($dav->put(-local => $file, -url => "$upload_dir/$upload_name")) {
    $logger->info("Uploaded file $file ok");
    return 1;
  } else {
    $logger->warn("Error uploading file $file:" . $dav->message);
    return 0;
  };
};

# check wether we have a suitable network connection
sub test_connectivity {
  my $bus = Net::DBus->system;
  my $service = $bus->get_service("net.connman");
  my $object  = $service->get_object("/", "net.connman.Manager");

  my $services = $object->GetServices;
  foreach my $service (@$services) {
    my $info = $service->[1];
    $logger->debug("Service '" . $info->{'Name'} . "' type " . $info->{'Type'} . " state " . $info->{'State'});
    if($info->{'Type'} eq 'wifi' and $info->{'State'} eq 'online') {
      $logger->debug("Is online on wifi");
      return 1 if $upload_on_wifi;
    };
    if($info->{'Type'} eq 'cellular' and $info->{'State'} eq 'online') {
      my $roaming = $info->{'Roaming'};
      $logger->debug('Is online on cellular, roaming') if $roaming;
      $logger->debug('Is online on cellular, not roaming') unless $roaming;
      if($upload_on_cellular) {
        if($roaming) {
          return 1 if $upload_on_roaming;
        } else {
          return 1;
        };
      };
    };
  };

  return 0;
};
