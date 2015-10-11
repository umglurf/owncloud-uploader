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
my $upload_on_roaming = 0;
$upload_on_roaming = 1 if $conf->param('upload_on_roaming') && $conf->param('upload_on_roaming') == 1;

# start dispatcer
# Instead of complicated thread synchronization or other schemes, we simply
# start up a child process to handle new files to be uploaded. This process
# again starts up one new process per file which will run until upload is
# successfull
# We start up the dispatcher before opening up the dbus socket to avoid having
# to close it again and to save memory
my $child = Child->new(sub {
    my $self = shift;
    $SIG{CHLD} = 'IGNORE';
    while(1) {
      my $file = $self->read();
      chomp $file;
      my $child = Child->new(sub {
          upload_picture($file);
        });
      my $proc = $child->start;
    };
  }, pipe => 1);
my $dispatcher = $child->start;

# read non-uploaded files and resume
# We save each file to be uploaded as a symlink, thus beeing able to resume
# upload on restart of the program
if(opendir(my $dir, $uploads_dir)) {
  while(my $file = readdir($dir)) {
    next if $file =~ /^\.\.?$/;
    next unless -l "$uploads_dir/$file";
    $logger->info("Resuming upload of $file");
    $dispatcher->say("$uploads_dir/$file");
  };
  closedir($dir);
} else {
  $logger->warn("Unable to open $uploads_dir: $!, skipping resume of uploads");
};

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
  next unless $class eq 'http://www.tracker-project.org/temp/nmm#Photo';
  foreach my $insert (@$inserts) {
    my $ids = join(',', @$insert);
    my $result = $object->SparqlQuery("SELECT ?t { ?r nie:url ?t .FILTER (tracker:id(?r) IN ($ids)) }");
    next unless $result->[0]->[0] =~ qr{^file://(.*)};
    next if exists $seen_files{$1};
    $logger->debug("Adding $1 to upload queue");
    $seen_files{$1} = time;
    $dispatcher->say($1);
    my $key;
    my $value;
    # purge out cache to save memory
    while(($key, $value) = each %seen_files) {
      delete $seen_files{$key} if (time() - $value) > 3600;
    };
  };
};

# This is the process handling upload of one file, it will run forever until
# file upload is successfull or the file has been deleted
sub upload_picture {
  my $file = shift;
  my ($name,$path,$suffix) = fileparse($file);
  unless(-l "$uploads_dir/$name") { # resuming old upload
    unless(symlink($file, "$uploads_dir/$name")) {
      $logger->warn("Unable to make symlink for $file, it will not be resumed on restart if it is not finished uploading");
    };
  };
  while(!do_picture_upload($file)) {
    sleep(300);
  };
  unlink("$uploads_dir/$name");
};

# do actual upload to owncloud
sub do_picture_upload {
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
  if($dav->put(-local => $file, -url => $upload_dir)) {
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
      return 1;
    } elsif($info->{'Type'} eq 'cellular' and $info->{'State'} eq 'online') {
      my $roaming = $info->{'Roaming'};
      $logger->debug('Is online on cellular, roaming') if $roaming;
      $logger->debug('Is online on cellular, not roaming') unless $roaming;
      return 1 if $roaming and $upload_on_roaming;
      return 1 unless $roaming;
    };
  };

  return 0;
};
