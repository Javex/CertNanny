#
# CertNanny - Automatic renewal for X509v3 certificates using SCEP
# 2005-02 Martin Bartosch <m.bartosch@cynops.de>
#
# This software is distributed under the GNU General Public License - see the
# accompanying LICENSE file for more details.
#

package CertNanny::Keystore::MQ;

use base qw(Exporter CertNanny::Keystore::OpenSSL);

use strict;

# use Smart::Comments;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);
use Exporter;
use Carp;

use CertNanny::Keystore;
use CertNanny::Keystore::OpenSSL;

use Data::Dumper;
use IO::File;
use File::Copy;
use File::Basename;
use Cwd;

$VERSION = 0.6;



# constructor parameters:
# location - base name of keystore (required)
# type - keystore type (default: auto)
sub new 
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = ( 
        @_,         # argument pair list
    );

    my $self = {};
    bless $self, $class;

    $self->{OPTIONS} = \%args;

    # get keystore PIN
    $self->{PIN} = $self->unstash($self->{OPTIONS}->{ENTRY}->{location} . ".sth");

    $self->{OPTIONS}->{tmp_dir} = 
	$args{CONFIG}->get('path.tmpdir', 'FILE');
    $self->{OPTIONS}->{gsk6cmd} =
	$args{CONFIG}->get('cmd.gsk6cmd', 'FILE');

    croak "No tmp_dir specified" unless (defined $self->{OPTIONS}->{tmp_dir});
    croak "gsk6cmd not found" unless (defined $self->{OPTIONS}->{gsk6cmd} and
				      -x $self->{OPTIONS}->{gsk6cmd});

    # set key generation operation mode:
    # internal: create RSA key and request with MQ keystore
    # external: create RSA key and request outside MQ keystore (OpenSSL)
    #           and import resulting certificate/key as PKCS#12 into keystore 
    $self->{OPTIONS}->{keygenmode} = "external";
    if (exists $self->{OPTIONS}->{ENTRY}->{keygenmode}) {
	$self->{OPTIONS}->{keygenmode} = 
	    $self->{OPTIONS}->{ENTRY}->{keygenmode};
    }
    
    croak "Illegal keygenmode: $self->{OPTIONS}->{keygenmode}" unless 
	($self->{OPTIONS}->{keygenmode} =~ /^(external)$/);

    # get previous renewal status
    $self->retrieve_state() or return undef;

    # check if we can write to the file
    $self->store_state() || croak "Could not write state file $self->{STATE}->{FILE}";
    
    # instantiate keystore
    return ($self);
}

sub DESTROY {
    my $self = shift;
    # check for an overridden destructor...
    $self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
}

# arg: array
# return: array with pins replaced
sub hidepin {
    my @args = @_;
    for (my $ii = 0; $ii < $#args; $ii++) {
	$args[$ii + 1] = "*HIDDEN*" if ($args[$ii] =~ /(-pw|-target_pw|-storepass|-keypass)/);
    }
    @args;
}


# determine location of the JAVA binary and the necessary CLASSPATH
# definition for GSKit
# sets global option JAVA to the location of the Java executable
# sets global option GSKIT_CLASSPATH to classpath required for accessing
#   the IBM GSKIT Keystore Implementation
sub getIBMJavaEnvironment
{
    my $self = shift;

    return 1 if ((exists $self->{OPTIONS}->{JAVA}) and 
		 (exists $self->{OPTIONS}->{GSKIT_CLASSPATH}));

    my $javacmd = File::Spec->catfile($ENV{JAVA_HOME}, 'bin', 'java');
    if (! -x $javacmd) {
	$self->seterror("getIBMJavaEnvironment(): could not determine Java executable (JAVA_HOME not set?)");
	return undef;
    }
    $self->{OPTIONS}->{JAVA} = $javacmd;
    
    # determine classpath for IBM classes
    my $gsk6cmd = $self->{OPTIONS}->{gsk6cmd};

    my $cmd = ". $gsk6cmd >/dev/null 2>&1 ; echo \$JAVA_FLAGS";
    $self->log({ MSG => "Execute: $cmd",
		 PRIO => 'debug' });
    my $classpath = `$cmd`;
    chomp $classpath;

    if (($? != 0) or (! defined $classpath) or ($classpath eq "")) {
	$self->seterror("getIBMJavaEnvironment(): could not determine GSK classpath");
	return undef;
    }
    # remove any options left over
    $classpath =~ s/-?-\w+//g;
    $classpath =~ s/^\s*//g;
    $classpath =~ s/\s*$//g;

    $self->debug("gsk6cmd classpath: $classpath");

    $self->{OPTIONS}->{GSKIT_CLASSPATH} = $classpath;

    return 1;
}


# descramble password in MQ stash file
sub unstash
{
    my $self = shift;
    my $stashfile = shift;

    my $fh = new IO::File("<$stashfile");
    if (! $fh)
    {
    	$self->seterror("unstash(): Could not open input file $stashfile");
    	return undef;
    }

    local $/;
    my $content = <$fh>;
    $fh->close();

    # =8->
    my $result = pack("C*", map { $_ ^ 0xf5 } unpack("C*", $content)); 
    return substr($result, 0, index($result, chr(0)));
}


# get label of end entity certificate
sub getcertlabel {
    my $self = shift;

    if (exists $self->{CERTLABEL}) {
	return $self->{CERTLABEL};
    }

    my $filename = $self->{OPTIONS}->{ENTRY}->{location};
    
    return undef unless (-r "$filename.kdb");

    my $gsk6cmd = $self->{OPTIONS}->{gsk6cmd};
    croak "Could not get gsk6cmd location" unless defined $gsk6cmd;

    # get label name for user certificate
    my @cmd = (qq("$gsk6cmd"),
	       '-cert',
	       '-list',
	       'personal',
	       '-db',
	       qq("$filename.kdb"),
	       '-pw',
	       qq("$self->{PIN}"));
    
    $self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
		 PRIO => 'debug' });

    local *HANDLE;
    if (!open HANDLE, join(" ", @cmd) . "|")
    {
	$self->seterror("getcert(): could not run gsk6cmd");
	return undef;
    }

    my $label;
    my $match = $self->{OPTIONS}->{ENTRY}->{labelmatch} || "ibmwebspheremq.*";

    while (<HANDLE>) {
	chomp;
	next if /Certificates in database/;
	s/^\s*//;
	s/\s*$//;
	if (!defined $match or
	    /$match/)
	{
	    $label = $_;
	    last;
	}
    }
    close HANDLE;

    if (! defined $label) {
	$self->seterror("getcert(): could not get label");
	return undef;
    }

    # cache information
    $self->{CERTLABEL} = $label;

    return $label;
}


# export existing private key
sub getkey {
    my $self = shift;

    # initialize Java and GSKit environment
    if (! $self->getIBMJavaEnvironment()) {
	$self->seterror("Could not determine IBM Java environment");
	return undef;
    }

    my $openssl = $self->{OPTIONS}->{CONFIG}->get('cmd.openssl', 'FILE');
    if (! defined $openssl) {
	$self->seterror("No openssl shell specified");
	return undef;
    }

    my $keystore = $self->{OPTIONS}->{ENTRY}->{location} . ".kdb";

    my $label = $self->getcertlabel();
    if (! defined $label) {
	$self->seterror("Could not get certificate label");
	return undef;
    }

    my $p8file = $self->gettmpfile();
    chmod 0600, $p8file;

    my $extractkey_jar = 
	File::Spec->catfile($self->{OPTIONS}->{CONFIG}->get("path.libjava", "FILE"),
					     'ExtractKey.jar');
    if (! -r $extractkey_jar) {
	$self->seterror("getkey(): could not locate ExtractKey.jar file");
	return undef;
    }

    my $classpath = $self->{OPTIONS}->{GSKIT_CLASSPATH} . ":" . $extractkey_jar;
    my @cmd;
    @cmd = (qq("$self->{OPTIONS}->{JAVA}"),
	    '-classpath',
	    qq("$classpath"),
	    'de.cynops.java.crypto.keystore.ExtractKey',
	    '-keystore',
	    qq("$keystore"),
	    '-storepass',
	    qq("$self->{PIN}"),
	    '-keypass',
	    qq("$self->{PIN}"),
	    '-key',
	    qq("$label"),
	    '-keyfile',
	    qq("$p8file"),
	    '-provider',
	    'IBMJCE',
	    '-type',
	    'CMS',
	);

    $self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
		 PRIO => 'debug' });
    if (system (join(' ', @cmd)) != 0)
    {
	$self->seterror("getkey(): could not extract private key");
	unlink $p8file;
	return undef;
    }

    my $keydata = $self->read_file($p8file);
    unlink $p8file;

    if ((! defined $keydata) or ($keydata eq "")) {
	$self->seterror("getkey(): Could not convert private key");
	return undef;
    }

    return (
	{ 
	    KEYDATA => $keydata,
	    KEYTYPE => 'PKCS8',
	    KEYFORMAT => 'DER',
	    # no keypass, unencrypted
	});
}


# export certificate in PEM format
sub getcert {
    my $self = shift;

    if (exists $self->{CERTINFO}) {
	return $self->{CERTINFO};
    }

    my $filename = $self->{OPTIONS}->{ENTRY}->{location};
    
    return undef unless (-r "$filename.kdb");

    my $gsk6cmd = $self->{OPTIONS}->{gsk6cmd};

    my $label = $self->getcertlabel();
    if (! defined $label) {
	$self->seterror("getcert(): could not get label");
	return undef;
    }

    my $certfile = $self->gettmpfile();
    # get label name for user certificate
    my @cmd;
    @cmd = (qq("$gsk6cmd"),
	    '-cert',
	    '-extract',
	    '-db',
	    qq("$filename.kdb"),
	    '-pw',
	    qq("$self->{PIN}"),
	    '-label',
	    qq("$label"),
	    '-target',
	    qq("$certfile"),
	    '-format',
	    'binary');

    $self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
		 PRIO => 'debug' });

    if (system (join(' ', @cmd)) != 0)
    {
	$self->seterror("getcert(): could not extract certificate");
	unlink $certfile;
	return undef;
    }

    # read certificate from file and remove temp file
    my $fh = new IO::File("<$certfile");
    if (! $fh)
    {
    	$self->seterror("getcert(): Could not open input file $certfile");
    	return undef;
    }

    local $/;
    my $content = <$fh>;
    $fh->close();

    unlink $certfile;

    $self->{CERTINFO}->{LABEL} = $label;
    $self->{CERTINFO}->{CERTDATA} = $content;
    $self->{CERTINFO}->{CERTFORMAT} = "DER";
    
    return ($self->{CERTINFO});
}



sub createrequest {
    my $self = shift;
    
    my $result;

    my $DN = $self->{CERT}->{INFO}->{SubjectName};
    
    $self->debug("DN: $DN");
    
    if ($self->{OPTIONS}->{keygenmode} eq "external") {
	$self->info("External request generation (using OpenSSL)");
	return $self->SUPER::createrequest() 
	    if $self->can("SUPER::createrequest");
    }
#    elsif ($self->{OPTIONS}->{keygenmode} eq "internal") {
# 	my $gsk6cmd = $self->{OPTIONS}->{gsk6cmd};
	
# 	my $kdbfile = File::Spec->catfile($self->{OPTIONS}->{ENTRY}->{statedir},
# 					  "renewal.kdb");
	
# 	my $label = $self->{CERT}->{LABEL};
# 	$self->debug("Label: $label");

# 	my @cmd = (qq("$gsk6cmd"),
# 		   '-certreq',
# 		   '-create',
# 		   '-file',
# 		   qq("$result->{REQUESTFILE}"),
# 		   '-db',
# 		   qq("$kdbfile"),
# 		   '-pw',
# 		   qq("$self->{PIN}"),
# 		   '-dn',
# 		   qq("$DN"),
# 		   '-label',
# 		   qq("$label"),
# 		   '-size',
# 		   '1024');

#     $self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
# 		 PRIO => 'debug' });

# 	if (system(join(' ', @cmd)) != 0) {
# 	    $self->seterror("Request creation failed");
# 	    return undef;
# 	}
#    }

    return $result;
}


sub installcert {
    my $self = shift;
    my %args = ( 
		 @_,         # argument pair list
		 );

    my $gsk6cmd = $self->{OPTIONS}->{gsk6cmd};

    # new MQ keystore base filename
    my $newkeystorebase = 
	File::Spec->catfile($self->{OPTIONS}->{ENTRY}->{statedir},
			    "tmpkeystore-" . $self->{OPTIONS}->{ENTRYNAME});
    
    my $newkeystoredb = $newkeystorebase . ".kdb";
    
    # clean up
    unlink $newkeystoredb;
    
    
    if ($self->{OPTIONS}->{keygenmode} eq "external") {
	$self->info("Creating MQ keystore (via PKCS#12)");

	# create prototype PKCS#12 file
	my $keyfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{KEYFILE};
	my $certfile = $args{CERTFILE};
	my $label = $self->{CERT}->{LABEL};
	
	$self->info("Creating prototype PKCS#12 from certfile $certfile, keyfile $keyfile, label $label");


# 	# build array of ca certificate filenames
# 	my @cachain;
# 	foreach my $entry (@{$self->{STATE}->{DATA}->{CERTCHAIN}}) {
# 	    print Dumper $entry;
# 	    push(@cachain, $entry);
# 	}

	# pkcs12file must be an absolute filename (see below, gsk6cmd bug)
	my $pkcs12file = $self->createpkcs12(FILENAME => $self->gettmpfile(),
					     FRIENDLYNAME => $label,
					     EXPORTPIN => $self->{PIN});
#					     CACHAIN => \@cachain);
	
	if (! defined $pkcs12file) {
	    $self->seterror("Could not create prototype PKCS#12 from received certificate");
	    return undef;
	}
	$self->info("Created PKCS#12 file $pkcs12file");

	# FIXME: create new pin?
	my @cmd;
	@cmd = (qq("$gsk6cmd"),
		'-keydb',
		'-create',
		'-type',
		'cms',
		'-db',
		qq("$newkeystoredb"),
		'-pw',
		qq("$self->{PIN}"),
		'-stash',
		);

	$self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
		     PRIO => 'debug' });
	
	if (system(join(' ', @cmd)) != 0) {
	    $self->seterror("Keystore creation failed");
	    return undef;
	}

	$self->info("New MQ Keystore $newkeystoredb created.");

	# remove all certificates from this keystore
	
	@cmd = (qq("$gsk6cmd"),
		'-cert',
		'-list',
		'-db',
		qq("$newkeystoredb"),
		'-pw',
		qq("$self->{PIN}"),
		);

	$self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
		     PRIO => 'debug' });
	
	my @calabels;

	local *HANDLE;
	if (! open HANDLE, join(' ', @cmd) . " |") {
	    $self->seterror("Could not retrieve certificate list in MQ keystore");
	    return undef;
	}
	while (<HANDLE>) {
	    chomp;
	    s/^\s*//;
	    s/\s*$//;
	    next if (/^Certificates in database/);
	    next if (/^No key/);
	    push(@calabels, $_);
	}
	close HANDLE;
	
	# now delete all preloaded CAs
	foreach (@calabels) {
	    $self->debug("deleting label '$_' from MQ keystore");

	    @cmd = (qq("$gsk6cmd"),
		    '-cert',
		    '-delete',
		    '-db',
		    qq("$newkeystoredb"),
		    '-pw',
		    qq("$self->{PIN}"),
		    '-label',
		    qq("$_"),
		    );

	    $self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
			 PRIO => 'debug' });
	    
	    if (system(join(' ', @cmd)) != 0) {
		$self->seterror("Could not delete certificate from keystore");
		return undef;
	    }
	}

	# keystore is now empty
	# subordinate certificates from the CA Cert chain

	# all trusted Root CA certificates...
	my @trustedcerts = @{$self->{STATE}->{DATA}->{ROOTCACERTS}};
	
	# ... plus all certificates from the CA key chain minus its root cert
	push(@trustedcerts, 
	     @{$self->{STATE}->{DATA}->{CERTCHAIN}}[1..$#{$self->{STATE}->{DATA}->{CERTCHAIN}}]);
			     
	foreach my $entry (@trustedcerts) {
	    my @RDN = split(/(?<!\\),\s*/, $entry->{CERTINFO}->{SubjectName});
	    my $CN = $RDN[0];
	    $CN =~ s/^CN=//;


	    $self->info("Adding certificate '$entry->{CERTINFO}->{SubjectName}' from file $entry->{CERTFILE}");

	    # rewrite certificate into PEM format
	    my $cacert = $self->convertcert(OUTFORMAT => 'PEM',
					    CERTFILE => $entry->{CERTFILE},
					    CERTFORMAT => 'PEM',
		);
	    
	    if (! defined $cacert)
	    {
		$self->seterror("installcert(): Could not convert certificate $entry->{CERTFILE}");
		return undef;
	    }

	    my $cacertfile = $self->gettmpfile();
	    my $fh = new IO::File(">$cacertfile");
	    if (! $fh)
	    {
		$self->seterror("installcert(): Could not create temporary file");
		return undef;
	    }
	    print $fh $cacert->{CERTDATA};
	    $fh->close();
	    

	    @cmd = (qq("$gsk6cmd"),
		    '-cert',
		    '-add',
		    '-db',
		    qq("$newkeystoredb"),
		    '-pw',
		    qq("$self->{PIN}"),
		    '-file',
		    qq("$cacertfile"),
		    '-format',
		    'ascii',
		    '-label',
		    qq("$CN"),
		    );

	    $self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
			 PRIO => 'debug' });
	    
	    if (system(join(' ', @cmd)) != 0) {
		unlink $cacertfile;
		$self->seterror("Could not add certificate to keystore");
		return undef;
	    }
	    unlink $cacertfile;

	}

	# finally add the PKCS#12 file to the keystore

	# NOTE: gsk6cmd contains a bug that makes it impossible to
	# specify absolute path names as -target
	# pkcs12file is guaranteed to be an absolute pathname (see above),
	# so it is safe to chdir to the target directory temporarily
	my ($basename, $dirname)  = fileparse($newkeystoredb);
	my $lastdir = getcwd();
	if (! chdir($dirname)) {
	    $self->seterror("Could not import PKCS#12 file to keystore (chdir to $dirname failed)");
	    return undef;
	}

	@cmd = (qq("$gsk6cmd"),
		'-cert',
		'-import',
		'-target',
		qq("$basename"),
		'-target_pw',
		qq("$self->{PIN}"),
		'-file',
		qq("$pkcs12file"),
		'-pw',
		qq("$self->{PIN}"),
		'-type',
		'pkcs12',
		);

	$self->log({ MSG => "Execute: " . join(" ", hidepin(@cmd)),
		     PRIO => 'debug' });
	
	if (system(join(' ', @cmd)) != 0) {
	    $self->seterror("Could not import PKCS#12 file to keystore");
	    chdir($lastdir);
	    return undef;
	}
	chdir($lastdir);

	$self->info("Keystore created");
    }
    elsif ($self->{OPTIONS}->{keygenmode} eq "internal") {
	$self->info("Internal key generation not supported");

#  	my @cmd = (qq("$gsk6cmd"),
#  		   '-certreq',
#  		   '-create',
#  		   '-file',
#  		   qq("$result->{REQUESTFILE}"),
#  		   '-db',
#  		   qq("$kdbfile"),
#  		   '-pw',
#  		   qq("$self->{PIN}"),
#  		   '-dn',
#  		   qq("$DN"),
#  		   '-label',
#  		   qq("$label"),
#  		   '-size',
#  		   '1024');
		   

	return undef;
    }

    # now replace the old keystore with the new one

    if (-r $newkeystoredb) {
	$self->info("Installing MQ keystore");

	my $oldlocation = $self->{OPTIONS}->{ENTRY}->{location};
	foreach my $ext (qw(.crl .rdb .kdb .sth)) {
	    # backup old keystore
	    my $mode = (stat($oldlocation . $ext))[2];
	    rename $oldlocation . $ext, $oldlocation . $ext . ".backup";

	    if (!copy($newkeystorebase . $ext, $oldlocation . $ext)) {
		$self->seterror("Could not copy keystore file " . $newkeystorebase . $ext);
		# FIXME: undo
		return undef;
	    }
	    unlink $newkeystorebase . $ext;
	    chmod $mode, $oldlocation . $ext;
	}
    }

    $self->renewalstate("completed");
    return 1;
}


1;