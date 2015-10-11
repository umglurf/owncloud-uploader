# owncloud-uploader
A owncloud uploader program, automatically uploading based on dbus events. This
program was written to automatically upload pictures from the [jolla
phone](http://jolla.com "jolla phone"), but should be able to work in other
scenarios as well. It will wait for tracker dbus signals looking for new
pictures and adding them to the upload queue. It will then try to upload to the
configured owncloud server if there is a working network connection. In case of
failure, it will wait and try again.

## Installation
For the jolla phone, you need to install the following packages using `pkcon
install` (after doing `devel-su`)
 * perl-CPAN
 * perl-libwww-perl
 * make
 * automake
 * gcc
 * gcc-c++
 * perl-XML-Parser
 * openssl-devel
 * systemd-devel
 
You then need to install as the normal nemo user
[local::lib](http://search.cpan.org/~haarg/local-lib-2.000017/lib/local/lib.pm "local::lib")
Follow the instructions under "The bootstrapping technique"
Then install the required cpan modules
 * Crypt::SSLeay
 * HTTP::DAV
 * Net::DBus
 * Child
 * Config::Simple
 * Log::Log4perl
 * Log::Log4perl::Appender::Journald
 
and then finally running make install to set up
 
## Configuration
Edit the configuration in `~/.config/owncloud-uploader` and then run `systemctl
--user restart owncloud-uploader`
