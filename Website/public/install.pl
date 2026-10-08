#!/usr/bin/perl
# Piped to sh by mistake, sh runs the next line and stops; Perl skips it.
eval 'echo "pomme install: this installer runs with Perl: curl -fsSL https://pommevm.dev/install.pl | perl" >&2; exit 1'
    if 0;

# Installs the pomme command-line tool from a Pomme release on GitHub, with
# the Perl that macOS includes:
#
#   curl -fsSL https://pommevm.dev/install.pl | perl
#   curl -fsSL https://pommevm.dev/install.pl | POMME_CHANNEL=alpha perl
#
# Piped to Perl, options go in environment variables, or after `perl -`, as
# in `perl - --alpha`; Perl reads anything before the program as its own.
#
# The installer downloads the release tarball and SHA256SUMS, checks the
# tarball's digest, checks that pomme carries Pomme's Developer ID signature,
# and then installs pomme in ~/.local/bin in one atomic step. It never edits
# your shell startup files. `pomme update` runs this script to update an
# install that it made. For the options, run it with --help.
#
# Everything runs from main on the last line, and Perl compiles the whole
# program first, so a partly downloaded script does nothing.

use strict;
use warnings;
use Digest::SHA ();
use File::Compare ();
use File::Copy ();
use File::Path ();
use File::Temp ();
use JSON::PP ();
use POSIX ();

my $repository = 'weswhet/pomme';
# The designated requirement of every Pomme release. Keychain items that
# Pomme creates trust only executables that satisfy it.
my $requirement = 'anchor apple generic and identifier "com.github.weswhet.pomme" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2D8XQ77EBQ"';
my $installer_authority = 'Developer ID Installer: Wesley Whetstone (2D8XQ77EBQ)';

my $usage = <<'USAGE';
Usage: perl install.pl [--version VERSION] [--alpha] [--install-dir DIR] [--package]
       curl -fsSL https://pommevm.dev/install.pl | perl - [OPTIONS]

Installs the pomme command-line tool from a Pomme release.

  --version VERSION  Install this version, such as 0.1.0 or 0.1.0-alpha.3.
                     By default, install the newest release.
  --alpha            Install the newest alpha or release, whichever is newer.
  --install-dir DIR  Install pomme in DIR, an absolute path. The default is
                     ~/.local/bin.
  --package          Install with the signed installer package instead, which
                     puts pomme in /usr/local/bin. This runs sudo.
  -h, --help         Show this help.

Environment variables set the same options without `perl -`:
POMME_VERSION=VERSION, POMME_CHANNEL=alpha, POMME_INSTALL_DIR=DIR, and
POMME_PACKAGE=1.
USAGE

# Tests serve a release from a local directory through these two variables.
# They can't weaken the signature check, which is the same for any source.
my $download_url = $ENV{POMME_DOWNLOAD_URL} || "https://github.com/$repository/releases/download";
my $api_url = $ENV{POMME_API_URL} || "https://api.github.com/repos/$repository";

my $work;        # The private temporary directory.
my $staged = ''; # A partly installed copy to remove if the install stops.

$| = 1;
sub say_line { print "$_[0]\n" }
sub fail {
    print STDERR "pomme install: $_[0]\n";
    exit 1;
}
END { unlink $staged if $staged }
$SIG{INT} = sub { exit 130 };
$SIG{TERM} = sub { exit 143 };

# Runs a command without a shell, and returns whether it succeeded. With
# quiet, its standard error goes to /dev/null.
sub run {
    my ($options, @command) = @_;
    my $pid = fork;
    fail("Couldn't run $command[0].") unless defined $pid;
    if ($pid == 0) {
        if ($options->{quiet}) { open STDERR, '>', '/dev/null' or POSIX::_exit(127) }
        exec { $command[0] } @command or POSIX::_exit(127);
    }
    waitpid $pid, 0;
    return $? == 0;
}

# Runs a command without a shell, and returns its success and output. With
# merge, the output includes standard error; otherwise standard error goes to
# /dev/null.
sub capture {
    my ($options, @command) = @_;
    my $pid = open(my $output, '-|');
    fail("Couldn't run $command[0].") unless defined $pid;
    if ($pid == 0) {
        if ($options->{merge}) { open STDERR, '>&', \*STDOUT or POSIX::_exit(127) }
        else { open STDERR, '>', '/dev/null' or POSIX::_exit(127) }
        exec { $command[0] } @command or POSIX::_exit(127);
    }
    my $text = do { local $/; <$output> } // '';
    close $output;
    return ($? == 0, $text);
}

sub curl_options {
    my ($url) = @_;
    return $url =~ m{^https://}
        ? ('--proto', '=https', '--tlsv1.2', '--retry', '3')
        : ();
}

sub fetch {
    my ($url, $path) = @_;
    return run({}, '/usr/bin/curl', curl_options($url),
               '--fail', '--silent', '--show-error', '--location', '--output', $path, $url);
}

sub read_file {
    my ($path) = @_;
    open my $file, '<:raw', $path or return undef;
    local $/;
    return scalar <$file>;
}

# Returns the tag of the newest release, or of the newest alpha or release.
sub latest_tag {
    my ($channel) = @_;
    my $json = "$work/releases.json";
    my $url = $channel eq 'alpha' ? "$api_url/releases?per_page=1" : "$api_url/releases/latest";
    my ($reached, $status) = capture({ merge => 0 }, '/usr/bin/curl', curl_options($url),
        '--silent', '--show-error', '--location', '--header', 'Accept: application/vnd.github+json',
        '--output', $json, '--write-out', '%{http_code}', $url);
    fail("Couldn't reach GitHub to find the newest Pomme release.") unless $reached;
    if ($status eq '404') {
        fail('No stable Pomme release is published yet. To install the newest alpha, run: curl -fsSL https://pommevm.dev/install.pl | POMME_CHANNEL=alpha perl');
    }
    fail("GitHub answered HTTP $status when asked for the newest Pomme release.")
        unless $status eq '200' || $status eq '000';
    my $releases = eval { JSON::PP->new->decode(read_file($json) // '') };
    if ($channel eq 'alpha') {
        my $tag = ref $releases eq 'ARRAY' && ref $releases->[0] eq 'HASH' ? $releases->[0]{tag_name} : undef;
        fail('No Pomme release is published yet.') unless defined $tag && !ref $tag;
        return $tag;
    }
    my $tag = ref $releases eq 'HASH' ? $releases->{tag_name} : undef;
    fail("GitHub's newest Pomme release has no tag.") unless defined $tag && !ref $tag;
    return $tag;
}

sub verify_signature {
    my ($path, $test) = @_;
    return run({ quiet => 1 }, '/usr/bin/codesign', '--verify', '--strict',
               '--test-requirement=' . ($test // "=$requirement"), $path);
}

# Checks a downloaded asset against its line in SHA256SUMS.
sub verify_digest {
    my ($path, $name) = @_;
    my $expected;
    for my $line (split /\n/, read_file("$work/SHA256SUMS") // '') {
        if ($line =~ /^([0-9a-fA-F]{64}) [ *](.+?)\s*$/ && $2 eq $name) {
            $expected = lc $1;
            last;
        }
    }
    fail("SHA256SUMS has no digest for $name.") unless defined $expected;
    my $actual = Digest::SHA->new(256)->addfile($path, 'b')->hexdigest;
    fail("$name doesn't match its SHA-256 digest in SHA256SUMS.") unless $actual eq $expected;
}

sub download_asset {
    my ($version, $name) = @_;
    fetch("$download_url/v$version/$name", "$work/$name")
        or fail("Couldn't download $name. Check that Pomme $version exists: https://github.com/$repository/releases");
    fetch("$download_url/v$version/SHA256SUMS", "$work/SHA256SUMS")
        or fail("Couldn't download SHA256SUMS for Pomme $version.");
    verify_digest("$work/$name", $name);
}

# Returns the first pomme that a shell would run from PATH.
sub pomme_on_path {
    for my $directory (split /:/, $ENV{PATH} // '') {
        next unless length $directory;
        my $candidate = "$directory/pomme";
        return $candidate if -f $candidate && -x _;
    }
    return undef;
}

sub install_tarball {
    my ($version, $install_dir) = @_;
    my $asset = "pomme-$version-arm64.tar.gz";
    my $destination = "$install_dir/pomme";
    # Check the destination before downloading anything.
    fail("$destination is a symbolic link. Remove it, or choose another directory with --install-dir.")
        if -l $destination;
    if (-e $destination) {
        fail("$destination isn't a regular file.") unless -f _;
        # Pomme's Keychain items trust only Pomme's Developer ID signature.
        # Replacing a differently signed pomme, such as an ad hoc build, would
        # silently change which executable can read them.
        verify_signature($destination)
            or fail("$destination isn't signed like Pomme's releases. Pomme's Keychain items trust only Pomme's Developer ID signature, so the installer won't replace it. To replace it, delete it first.");
    }

    say_line("Downloading Pomme $version.");
    download_asset($version, $asset);
    my $extract = "$work/extract";
    mkdir $extract, 0700 or fail("Couldn't create $extract.");
    run({ quiet => 1 }, '/usr/bin/tar', '-xzf', "$work/$asset", '-C', $extract)
        or fail("Couldn't unpack $asset.");
    opendir my $listing, $extract or fail("Couldn't unpack $asset.");
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $listing;
    closedir $listing;
    my $download = "$extract/pomme";
    fail("$asset doesn't contain just the pomme executable.")
        unless @entries == 1 && $entries[0] eq 'pomme' && !-l $download && -f $download;
    verify_signature($download)
        or fail("The pomme in $asset doesn't have Pomme's Developer ID signature.");
    if (-e $destination) {
        # Keychain items record the designated requirement of the pomme that
        # created them, so the new pomme must satisfy the installed one's.
        my (undef, $details) = capture({ merge => 1 }, '/usr/bin/codesign', '--display', '--requirements', '-', $destination);
        my ($installed_requirement) = $details =~ /^designated => (.+)$/m;
        unless (defined $installed_requirement && verify_signature($download, "=$installed_requirement")) {
            fail("The downloaded pomme doesn't satisfy the designated requirement of $destination, so it couldn't read the Keychain items that $destination created.");
        }
    }
    my ($ran, $reported) = capture({}, $download, '--version');
    fail("The downloaded pomme doesn't run on this Mac.") unless $ran;
    $reported =~ s/\s+\z//;
    fail("The downloaded pomme reports '$reported' instead of version $version.")
        unless index($reported, "pomme $version (") == 0;

    unless (-d $install_dir) {
        File::Path::make_path($install_dir, { error => \my $errors });
        fail("Couldn't create $install_dir.") unless -d $install_dir;
    }
    fail("You can't write to $install_dir. Choose another directory with --install-dir, or use --package.")
        unless -w $install_dir;
    # Copy to a new file and rename it, so that pomme is never partly written
    # and a running pomme keeps its own file.
    my $handle;
    ($handle, $staged) = eval { File::Temp::tempfile('.pomme-install.XXXXXX', DIR => $install_dir, UNLINK => 0) };
    fail("Couldn't write to $install_dir.") unless $handle;
    close $handle;
    File::Copy::copy($download, $staged) or fail("Couldn't write to $install_dir.");
    chmod 0755, $staged or fail("Couldn't write to $install_dir.");
    fail("The copy of pomme in $install_dir doesn't match the download.")
        unless File::Compare::compare($download, $staged) == 0 && verify_signature($staged);
    rename $staged, $destination or fail("Couldn't install $destination.");
    $staged = '';
    say_line("Installed pomme $version at $destination.");

    if (grep { $_ eq $install_dir } split /:/, $ENV{PATH} // '') {
        my $found = pomme_on_path();
        say_line("Warning: your shell runs $found, which comes before $destination in PATH.")
            if defined $found && $found ne $destination;
    } else {
        say_line("$install_dir isn't in your PATH. To add it for zsh, add this line to ~/.zprofile and open a new terminal window:");
        say_line("  export PATH=\"$install_dir:\$PATH\"");
    }
}

sub install_package {
    my ($version) = @_;
    my $asset = "pomme-$version-arm64.pkg";
    say_line("Downloading Pomme $version.");
    download_asset($version, $asset);
    my ($valid, $signature) = capture({ merge => 1 }, '/usr/sbin/pkgutil', '--check-signature', "$work/$asset");
    fail("$asset doesn't have a valid signature.") unless $valid;
    fail("$asset isn't signed by $installer_authority.") unless index($signature, $installer_authority) >= 0;
    say_line("Installing $asset. The installer needs administrator access.");
    my @installer = ('/usr/sbin/installer', '-pkg', "$work/$asset", '-target', '/');
    unshift @installer, '/usr/bin/sudo' unless $> == 0;
    run({}, @installer) or fail('The installer failed.');
    verify_signature('/usr/local/bin/pomme')
        or fail("/usr/local/bin/pomme doesn't have Pomme's Developer ID signature after the install.");
    say_line("Installed pomme $version at /usr/local/bin/pomme.");
}

sub main {
    my @arguments = @_;
    my $version = $ENV{POMME_VERSION} // '';
    my $channel = $ENV{POMME_CHANNEL} || 'stable';
    my $install_dir = $ENV{POMME_INSTALL_DIR} // '';
    my $package = ($ENV{POMME_PACKAGE} // '') eq '1' ? 1 : 0;
    while (@arguments) {
        my $argument = shift @arguments;
        if ($argument eq '--version') {
            fail('--version needs a version.') unless @arguments;
            $version = shift @arguments;
        } elsif ($argument =~ /^--version=(.*)$/s) {
            $version = $1;
        } elsif ($argument eq '--alpha') {
            $channel = 'alpha';
        } elsif ($argument eq '--install-dir') {
            fail('--install-dir needs a directory.') unless @arguments;
            $install_dir = shift @arguments;
        } elsif ($argument =~ /^--install-dir=(.*)$/s) {
            $install_dir = $1;
        } elsif ($argument eq '--package') {
            $package = 1;
        } elsif ($argument eq '-h' || $argument eq '--help') {
            print $usage;
            exit 0;
        } else {
            print STDERR $usage;
            fail("Unknown option: $argument");
        }
    }
    fail('POMME_CHANNEL must be stable or alpha.') unless $channel eq 'stable' || $channel eq 'alpha';
    fail('--package always installs in /usr/local/bin, so it takes no --install-dir.')
        if $package && length $install_dir;
    if (!length $install_dir) {
        fail('HOME is not set, so give a directory with --install-dir.') unless length($ENV{HOME} // '');
        $install_dir = "$ENV{HOME}/.local/bin";
    }
    fail("--install-dir needs an absolute path, not $install_dir.") unless $install_dir =~ m{^/};

    my (undef, undef, undef, undef, $machine) = POSIX::uname();
    fail('Pomme runs only on macOS.') unless $^O eq 'darwin';
    # A process running under Rosetta reports x86_64 on Apple silicon.
    if ($machine ne 'arm64') {
        my (undef, $translated) = capture({}, '/usr/sbin/sysctl', '-n', 'sysctl.proc_translated');
        fail('Pomme needs a Mac with Apple silicon.') unless ($translated // '') =~ /^1\s*$/;
    }
    my (undef, $product_version) = capture({}, '/usr/bin/sw_vers', '-productVersion');
    my ($macos_major) = ($product_version // '') =~ /^(\d+)/;
    fail('Pomme needs macOS 15 or later.') unless defined $macos_major && $macos_major >= 15;
    for my $tool ('/usr/bin/codesign', '/usr/bin/curl', '/usr/sbin/pkgutil', '/usr/bin/tar') {
        fail("This Mac is missing $tool.") unless -x $tool;
    }

    my $temporary = $ENV{TMPDIR} || '/tmp';
    $temporary =~ s{/+\z}{};
    $work = eval { File::Temp::tempdir("$temporary/pomme-install.XXXXXX", CLEANUP => 1) }
        or fail("Couldn't create a temporary directory.");

    $version = latest_tag($channel) unless length $version;
    $version =~ s/^v//;
    fail("'$version' isn't a Pomme version.") unless $version =~ /^[A-Za-z0-9.-]+\z/;

    if ($package) {
        install_package($version);
    } else {
        install_tarball($version, $install_dir);
    }
}

main(@ARGV);
