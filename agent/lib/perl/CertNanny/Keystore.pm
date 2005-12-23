#
# CertNanny - Automatic renewal for X509v3 certificates using SCEP
# 2005-02 Martin Bartosch <m.bartosch@cynops.de>
#
# This software is distributed under the GNU General Public License - see the
# accompanying LICENSE file for more details.
#

package CertNanny::Keystore;

use File::Glob qw(:globally :nocase);
use File::Spec;

use IO::File;
use File::Copy;
use File::Temp;
use File::Basename;
use Carp;
use Data::Dumper;

use CertNanny::Util;

use strict;
use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION $AUTOLOAD %accessible);
use Exporter;

$VERSION = 0.6;
@ISA = qw(Exporter);

# Authorize get/set access to certain attributes
for my $attr ( qw() ) { $accessible{$attr}++; }


# constructor parameters:
# location - base name of keystore (required)
sub new 
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = ( 
        @_,         # argument pair list
    );

    my $self = {};
    bless $self, $class;

    $self->{CONFIG} = $args{CONFIG};

    foreach my $item (qw(statedir scepcertdir)) {
	if (! exists $args{ENTRY}->{$item}) {
	    croak "No $item specified for keystore " . $args{ENTRY}->{location};
	}

	if (! -d $args{ENTRY}->{$item}) {
	    croak "$item directory $args{ENTRY}->{$item} does not exist";
	}

	if (! -x $args{ENTRY}->{$item} or
	    ! -r $args{ENTRY}->{$item} or
	    ! -w $args{ENTRY}->{$item}) {
	    croak "Insufficient permissions for $item $args{ENTRY}->{$item}";
	}
    }

    if (! exists $args{ENTRY}->{statefile}) {
	my $entry = $args{ENTRYNAME} || "entry";
	my $statefile = File::Spec->catfile($args{ENTRY}->{statedir}, "$entry.state");
	$args{ENTRY}->{statefile} = $statefile;
    }
    
    $self->loglevel($args{CONFIG}->get('loglevel') || 3);

    # set defaults
    $self->{OPTIONS}->{tmp_dir} = 
	$args{CONFIG}->get('path.tmpdir', 'FILE');
    $self->{OPTIONS}->{openssl_shell} =
	$args{CONFIG}->get('cmd.openssl', 'FILE');
    $self->{OPTIONS}->{sscep_cmd} =
	$args{CONFIG}->get('cmd.sscep', 'FILE');
    
    croak "No tmp directory specified" 
	unless defined $self->{OPTIONS}->{tmp_dir};

    croak "No openssl binary configured or found" 
	unless (defined $self->{OPTIONS}->{openssl_shell} and
		-x $self->{OPTIONS}->{openssl_shell});

    croak "No sscep binary configured or found" 
	unless (defined $self->{OPTIONS}->{sscep_cmd} and
		-x $self->{OPTIONS}->{sscep_cmd});
    

    # instantiate keystore
    my $type = $args{ENTRY}->{type};
    if ($type eq "none") {
	print STDERR "Skipping keystore (no keystore type defined)\n";
	return undef;
    }

    if (! $self->load_keystore_handler($type)) {
	print STDERR "ERROR: Could not load keystore handler '$type'\n";
	return undef;
    }

    # attach keystore handler
    # backend constructor is expected to perform sanity checks on the
    # configuration and return undef if options are not appropriate
    eval "\$self->{INSTANCE} = new CertNanny::Keystore::$type((\%args, \%{\$self->{OPTIONS}}))";
    if ($@) {
	print STDERR $@;
	return undef;
    }

    croak "Could not initialize keystore handler '$type'. Aborted." 
	unless defined $self->{INSTANCE};

    # get certificate
    $self->{CERT} = $self->{INSTANCE}->getcert();

    if (defined $self->{CERT}) {
	$self->{CERT}->{INFO} = $self->getcertinfo(%{$self->{CERT}});

	my %convopts = %{$self->{CERT}};

	$convopts{OUTFORMAT} = 'PEM';
	$self->{CERT}->{RAW}->{PEM}  = $self->convertcert(%convopts)->{CERTDATA};
	$convopts{OUTFORMAT} = 'DER';
	$self->{CERT}->{RAW}->{DER}  = $self->convertcert(%convopts)->{CERTDATA};
    } 
    else
    {
	print STDERR "ERROR: Could not parse instance certificate\n";
	return undef;
    }
    $self->{INSTANCE}->setcert($self->{CERT});

    # get previous renewal status
    #$self->retrieve_state() or return undef;

    # check if we can write to the file
    #$self->store_state() || croak "Could not write state file $self->{STATE}->{FILE}";

    return ($self);
}


sub DESTROY
{
    my $self = shift;
    
    $self->store_state();

    return unless (exists $self->{TMPFILE});

    foreach my $file (@{$self->{TMPFILE}}) {
	unlink $file;
    }
}

sub setcert {
    my $self = shift;
    
    $self->{CERT} = shift;
}


# convert certificate to other formats
# input: hash ref
# CERTDATA => string containing certificate data OR
# CERTFILE => file containing certificate data
# CERTFORMAT => certificate encoding format (PEM or DER), default: DER
# OUTFORMAT => desired output certificate format (PEM or DER), default: DER
#
# return: hash ref
# CERTDATA => string containing certificate data
# CERTFORMAT => certificate encoding format (PEM or DER)
# or undef on error
sub convertcert {
    my $self = shift;
    my %options = (
	CERTFORMAT => 'DER',
	OUTFORMAT => 'DER',
	@_,         # argument pair list
	);

    my $output;

    my $openssl = $self->{OPTIONS}->{openssl_shell};
    my $infile;

    my @cmd = (qq("$openssl"),
	       'x509',
	       '-in',
	);
    
    if (exists $options{CERTDATA}) {
	$infile = $self->gettmpfile();
	my $fh = new IO::File(">$infile");
	if (! $fh)
	{
	    $self->seterror("convertcert(): Could not create temporary file");
	    return undef;
	}
	print $fh $options{CERTDATA};
	$fh->close();
	push(@cmd, qq("$infile"));
    } else {
	push(@cmd, qq("$options{CERTFILE}"));
    }
    
    push(@cmd, ('-inform', $options{CERTFORMAT}));
    push(@cmd, ('-outform', $options{OUTFORMAT}));

    $output->{CERTFORMAT} = $options{OUTFORMAT};

    my $cmd = join(' ', @cmd);
    $output->{CERTDATA} = `$cmd`;
    unlink $infile if defined $infile;

    if ($? != 0) {
	$self->seterror("convertcert(): Could not convert certificate");
	return undef;
    }
    
    return $output;
}


sub loglevel {
    my $self = shift;
    $self->{OPTIONS}->{LOGLEVEL} = shift if (@_);

    if (! defined $self->{OPTIONS}->{LOGLEVEL}) {
	return 3;
    }
    return $self->{OPTIONS}->{LOGLEVEL};
}

# accessor method for renewal state
sub renewalstate {
    my $self = shift;
    if (@_) {
	$self->{STATE}->{DATA}->{RENEWAL}->{STATUS} = shift;
	my $hook = $self->{INSTANCE}->{OPTIONS}->{ENTRY}->{hook}->{renewal}->{state} || $self->{OPTIONS}->{ENTRY}->{hook}->{renewal}->{state};
	$self->executehook($hook,
			   '__STATE__' => $self->{STATE}->{DATA}->{RENEWAL}->{STATUS},
			   );
    }
    return $self->{STATE}->{DATA}->{RENEWAL}->{STATUS};
}


sub retrieve_state
{
    my $self = shift;

    my $file = $self->{OPTIONS}->{ENTRY}->{statefile};
    return 1 unless (defined $file and $file ne "");
    
    if (-r $file) {
	$self->{STATE}->{DATA} = undef;

	local *HANDLE;
	if (!open HANDLE, "<$file") {
	    croak "Could not read state file $file";
	}
	eval do { local $/; <HANDLE> };

	if (! defined $self->{STATE}->{DATA}) {
	    croak "Could not read state from file $file";
	}
    }
    return 1;
}

sub store_state
{
    my $self = shift;

    my $file = $self->{OPTIONS}->{ENTRY}->{statefile};
    return 1 unless (defined $file and $file ne "");

    # store internal state
    if (ref $self->{STATE}->{DATA}) {
	my $dump = Data::Dumper->new([$self->{STATE}->{DATA}],
				     [qw($self->{STATE}->{DATA})]);

	$dump->Purity(1);

	local *HANDLE;
	if (! open HANDLE, ">$file") {
	    croak "Could not write state to file $file";
	}
	print HANDLE $dump->Dump;
	close HANDLE;
    }
    
    return 1;
}



# get error message
# arg:
# return: error message description caused by the last operation (cleared 
#         after each query)
sub geterror
{
    my $self = shift;
    my $arg = shift;

    my $my_errmsg = $self->{ERRMSG};
    # clear error message
    $self->{ERRMSG} = undef if (defined $my_errmsg);

    # compose output
    my $errmsg;
    $errmsg = $my_errmsg if defined ($my_errmsg);

    $errmsg;
}

# set error message
# arg: error message
# message is also logged with priority ERROR
sub seterror
{
    my $self = shift;
    my $arg = shift;
    
    $self->{ERRMSG} = $arg;
    $self->log({ MSG => $arg,
		 PRIO => 'error' });
}

sub log
{
    my $self = shift;
    my $arg = shift;
    confess "Not a hash ref" unless (ref($arg) eq "HASH");
    return undef unless (defined $arg->{MSG});
    my $prio = lc($arg->{PRIO}) || "info";

    my %level = ( 'debug'  => 4,
		  'info'   => 3,
		  'notice' => 2,
		  'error'  => 1,
		  'fatal'  => 0 );


    print STDERR "WARNING: log called with undefined priority '$prio'" unless exists $level{$prio};
    if ($level{$prio} <= $self->loglevel()) {

	# fallback to STDERR
	print STDERR "LOG: [$prio] $arg->{MSG}\n";
	
	# call hook
	#$self->executehook($self->{INSTANCE}->{OPTIONS}->{ENTRY}->{hook}->{log},
#			   '__PRIORITY__' => $prio,
#			   '__MESSAGE__' => $arg->{MSG});
    }
    return 1;
}

sub debug
{
    my $self = shift;
    my $arg = shift;

#    if (exists $self->{DEBUG} and $self->{DEBUG}) {
	$self->log({ MSG => $arg,
		     PRIO => 'debug' });
#    }
}

sub info
{
    my $self = shift;
    my $arg = shift;

    $self->log({ MSG => $arg,
		 PRIO => 'info' });
}



# dynamically load keystore instance module
sub load_keystore_handler
{
    my $self = shift;
    my $arg = shift;
    
    eval "require CertNanny::Keystore::${arg}";
    if ($@) {
	print STDERR $@;
	return 0;
    }
    
    return 1;
}

# sub AUTOLOAD
# {
#     my $self = shift;
#     my $attr = $AUTOLOAD;
#     $attr =~ s/.*:://;
#     return if $attr eq 'DESTROY';   
    
#     if ($accessible{$attr}) {
#         $self->{uc $attr} = shift if @_;
#         return $self->{uc $attr};
#     } else {
# 	if (exists $self->{INSTANCE} and
# 	    $self->{INSTANCE}->can($attr)) {
# 	    $self->{INSTANCE}->$attr(@_);
# 	}
# 	else
# 	{
# 	    croak "Cannot autoload $attr";
# 	    die;
# 	}
#     } 
# }


# NOTE: this is UNSAFE (beware of race conditions). We cannot use a file
# handle here because we are calling external programs to use these
# temporary files.
sub gettmpfile
{
    my $self = shift;

    my $tmpdir = $self->{OPTIONS}->{tmp_dir};
    #if (! defined $tmpdir);
    my $template = File::Spec->catfile($tmpdir,
				       "cbXXXXXX");

    my $tmpfile =  mktemp($template);
    
    push (@{$self->{TMPFILE}}, $tmpfile);
    return ($tmpfile);
}


# parse DER encoded X.509v3 certificate and return certificate information 
# in a hash ref
# Prerequisites: requires external openssl executable
# options: hash
#   CERTDATA => directly contains certificate data
#   CERTFILE => cert file to parse
#   CERTFORMAT => PEM|DER (default: DER)
#
# return: hash reference containing the certificate information
# returns undef if both CERTDATA and CERTFILE are specified or on error
#
# Returned hash reference contains the following values:
# Version => <cert version, optional> Values: 2, 3
# SubjectName => <cert subject common name>
# IssuerName => <cert issuer common name>
# SerialNumber => <cert serial number> Format: xx:xx:xx... (hex, upper case)
# Serial => <cert serial number> As integer number
# NotBefore => <cert validity> Format: YYYYDDMMHHMMSS
# NotAfter  => <cert validity> Format: YYYYDDMMHHMMSS
# PublicKey => <cert public key> Format: Base64 encoded (PEM)
# Certificate => <certifcate> Format: Base64 encoded (PEM)
# BasicConstraints => <cert basic constraints> Text (free style)
# KeyUsage => <cert key usage> Format: Text (free style)
# CertificateFingerprint => <cert MD5 fingerprint> Format: xx:xx:xx... (hex, 
#   upper case)
#
# optional:
# SubjectAlternativeName => <cert alternative name> 
# IssuerAlternativeName => <issuer alternative name>
# SubjectKeyIdentifier => <X509v3 Subject Key Identifier>
# AuthorityKeyIdentifier => <X509v3 Authority Key Identifier>
# CRLDistributionPoints => <X509v3 CRL Distribution Points>
# 
sub getcertinfo
{
    my $self = shift;
    my %options = (
		   CERTFORMAT => 'DER',
		   @_,         # argument pair list
		   );
    

    my $certinfo = {};
    my %month = (
		 Jan => 1, Feb => 2,  Mar => 3,  Apr => 4,
		 May => 5, Jun => 6,  Jul => 7,  Aug => 8,
		 Sep => 9, Oct => 10, Nov => 11, Dec => 12 );

    my %mapping = (
		   'serial' => 'SerialNumber',
		   'subject' => 'SubjectName',
		   'issuer' => 'IssuerName',
		   'notBefore' => 'NotBefore',
		   'notAfter' => 'NotAfter',
		   'MD5 Fingerprint' => 'CertificateFingerprint',
		   'PUBLIC KEY' => 'PublicKey',
		   'CERTIFICATE' => 'Certificate',
		   'ISSUERALTNAME' => 'IssuerAlternativeName',
		   'SUBJECTALTNAME' => 'SubjectAlternativeName',
		   'BASICCONSTRAINTS' => 'BasicConstraints',
		   'SUBJECTKEYIDENTIFIER' => 'SubjectKeyIdentifier',
		   'AUTHORITYKEYIDENTIFIER' => 'AuthorityKeyIdentifier',
		   'CRLDISTRIBUTIONPOINTS' => 'CRLDistributionPoints',
		   );
	

    # sanity checks
    if (! (defined $options{CERTFILE} or defined $options{CERTDATA}))
    {
	$self->seterror("getcertinfo(): No input data specified");
	return undef;
    }
    if ((defined $options{CERTFILE} and defined $options{CERTDATA}))
    {
	$self->seterror("getcertinfo(): Ambigous input data specified");
	return undef;
    }
    
    my $outfile = $self->gettmpfile();
    my $openssl = $self->{OPTIONS}->{openssl_shell};

    my $inform = $options{CERTFORMAT};

    my @input = ();
    if (defined $options{CERTFILE}) {
	@input = ('-in', qq($options{CERTFILE}));
    }

    # export certificate
    my @cmd = (qq("$openssl"),
	       'x509',
	       @input,
	       '-inform',
	       $inform,
	       '-text',
	       '-subject',
	       '-issuer',
	       '-serial',
	       '-email',
	       '-startdate',
	       '-enddate',
	       '-modulus',
	       '-fingerprint',
	       '-pubkey',
	       '-purpose',
	       '>',
	       qq("$outfile"));

    $self->log({ MSG => "Execute: " . join(" ", @cmd),
		 PRIO => 'debug' });

    local *HANDLE;
    if (!open HANDLE, "|" . join(' ', @cmd))
    {
    	$self->seterror("getcertinfo(): open error");
	unlink $outfile;
	return undef;

    }

    if (defined $options{CERTDATA}) {
	print HANDLE $options{CERTDATA};
    }

    close HANDLE;
    
    if ($? != 0)
    {
    	$self->seterror("getcertinfo(): Error ASN.1 decoding certificate");
	unlink $outfile;
	return undef;
    }

    my $fh = new IO::File("<$outfile");
    if (! $fh)
    {
    	$self->seterror("getcertinfo(): Error analysing ASN.1 decoded certificate");
	unlink $outfile;
    	return undef;
    }

    my $state = "";
    my @purposes;
    while (<$fh>)
    {
	chomp;
	tr/\r\n//d;

	$state = "PURPOSE" if (/^Certificate purposes:/);
	$state = "PUBLIC KEY" if (/^-----BEGIN PUBLIC KEY-----/);
	$state = "CERTIFICATE" if (/^-----BEGIN CERTIFICATE-----/);
	$state = "SUBJECTALTNAME" if (/X509v3 Subject Alternative Name:/);
	$state = "ISSUERALTNAME" if (/X509v3 Issuer Alternative Name:/);
	$state = "BASICCONSTRAINTS" if (/X509v3 Basic Constraints:/);
	$state = "SUBJECTKEYIDENTIFIER" if (/X509v3 Subject Key Identifier:/);
	$state = "AUTHORITYKEYIDENTIFIER" if (/X509v3 Authority Key Identifier:/);
	$state = "CRLDISTRIBUTIONPOINTS" if (/X509v3 CRL Distribution Points:/);

	if ($state eq "PURPOSE")
	{
	    my ($purpose, $bool) = (/(.*?)\s*:\s*(Yes|No)/);
	    next unless defined $purpose;
	    push (@purposes, $purpose) if ($bool eq "Yes");

	    # NOTE: state machine will leave PURPOSE state on the assumption
	    # that 'OCSP helper CA' is the last cert purpose printed out
	    # by OpenCA. It would be best to have OpenSSL print out
	    # purpose information, just to be sure.
	    $state = "" if (/^OCSP helper CA :/);
	    next;
	}
	# Base64 encoded sections
	if ($state =~ /^(PUBLIC KEY|CERTIFICATE)$/)
	{
	    my $key = $state;
	    $key = $mapping{$key} if (exists $mapping{$key});

	    $certinfo->{$key} .= "\n" if (exists $certinfo->{$key});
	    $certinfo->{$key} .= $_ unless (/^-----/);

	    $state = "" if (/^-----END $state-----/);
	    next;
	}

	# X.509v3 extension one-liners
	if ($state =~ /^(SUBJECTALTNAME|ISSUERALTNAME|BASICCONSTRAINTS|SUBJECTKEYIDENTIFIER|AUTHORITYKEYIDENTIFIER|CRLDISTRIBUTIONPOINTS)$/)
	{
	    next if (/X509v3 .*:/);
	    my $key = $state;
	    $key = $mapping{$key} if (exists $mapping{$key});
	    # remove trailing and leading whitespace
	    s/^\s*//;
	    s/\s*$//;
	    $certinfo->{$key} = $_ unless ($_ eq "<EMPTY>");
	    
	    # alternative line consists of only one line 
	    $state = "";
	    next;
	}
	
 	if (/(Version:|subject=|issuer=|serial=|notBefore=|notAfter=|MD5 Fingerprint=)\s*(.*)/)
 	{
	    my $key = $1;
 	    my $value = $2;
	    # remove trailing garbage
	    $key =~ s/[ :=]+$//;
	    # apply key mapping
	    $key = $mapping{$key} if (exists $mapping{$key});

	    # store value
 	    $certinfo->{$key} = $value;
 	}
    }
    $fh->close();
    unlink $outfile;

    # compose key usage text field
    $certinfo->{KeyUsage} = join(", ", @purposes);
    
    # sanity checks
    foreach my $var qw(Version SerialNumber SubjectName IssuerName NotBefore NotAfter CertificateFingerprint)
    {
	if (! exists $certinfo->{$var})
	{
	    $self->seterror("getcertinfo(): Could not determine field '$var' from X.509 certificate");
	    return undef;
	}
    }


    ####
    # Postprocessing, rewrite certain fields

    ####
    # serial number
    # extract hex certificate serial number (only required for -text format)
    #$certinfo->{SerialNumber} =~ s/.*\(0x(.*)\)/$1/;

    # store decimal serial number
    $certinfo->{Serial} = hex($certinfo->{SerialNumber});

    # pad with a leading zero if length is odd
    if (length($certinfo->{SerialNumber}) % 2)
    {
	$certinfo->{SerialNumber} = '0' . $certinfo->{SerialNumber};
    }
    # convert to upcase and insert colons to separate hex bytes
    $certinfo->{SerialNumber} = uc($certinfo->{SerialNumber});
    $certinfo->{SerialNumber} =~ s/(..)/$1:/g;
    $certinfo->{SerialNumber} =~ s/:$//;

    ####
    # get certificate version
    $certinfo->{Version} =~ s/(\d+).*/$1/;

    ####
    # reverse DN order returned by OpenSSL
    foreach my $var qw(SubjectName IssuerName)
    {
	$certinfo->{$var} = join(", ", 
				 reverse split(/[\/,]\s*/, $certinfo->{$var}));
	# remove trailing garbage
	$certinfo->{$var} =~ s/[, ]+$//;
    }

    ####
    # rewrite dates from human readable to ISO notation
    foreach my $var qw(NotBefore NotAfter)
    {
	my ($mon, $day, $hh, $mm, $ss, $year, $tz) =
	    $certinfo->{$var} =~ /(\S+)\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d+)\s*(\S*)/;
	my $dmon = $month{$mon};
	if (! defined $dmon)
	{
	    $self->seterror("getcertinfo(): could not parse month '$mon' in date '$certinfo->{$var}' returned by OpenSSL");
	    return undef;
	}
	
	$certinfo->{$var} = sprintf("%04d%02d%02d%02d%02d%02d",
				    $year, $dmon, $day, $hh, $mm, $ss);
    }


    return $certinfo;
}


# return certificate information for this keystore
# optional arguments: list of entries to return
sub getinfo
{
    my $self = shift;
    my @elements = @_;

    return $self->{CERT}->{INFO} unless @elements;

    my $result;
    foreach (@elements) {
	$result->{$_} = $self->{CERT}->{INFO}->{$_};
    }
    return $result;
}

# return true if certificate is still valid for more than <days>
# return false otherwise
# return undef on error
sub checkvalidity {
    my $self = shift;
    my $days = shift || 0;
    
    my $notAfter = isodatetoepoch($self->{CERT}->{INFO}->{NotAfter});
    return undef unless defined $notAfter;

    my $cutoff = time + $days * 24 * 3600;

    return 1 if ($cutoff < $notAfter);
    if ($cutoff >= $notAfter) {
	$self->executehook($self->{INSTANCE}->{OPTIONS}->{ENTRY}->{hook}->{warnexpiry},
			   '__NOTAFTER__' => $self->{CERT}->{INFO}->{NotAfter},
			   '__NOTBEFORE__' => $self->{CERT}->{INFO}->{NotBefore},
			   '__STATE__' => $self->{STATE}->{DATA}->{RENEWAL}->{STATUS},
			   );
	return 0;
    }
    return undef;
}


# handle renewal operation
sub renew {
    my $self = shift;

    $self->renewalstate("initial") unless defined $self->renewalstate();
    my $laststate = "n/a";

    while ($laststate ne $self->renewalstate()) {
	$laststate = $self->renewalstate();
	# renewal state machine
	if ($self->renewalstate() eq "initial") {
	    $self->log({ MSG => "State: initial",
			 PRIO => 'debug' });
	    
	    $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST} = $self->createrequest();
	    
	    if (! defined $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}) {
		$self->log({ MSG => "Could not create certificate request",
			     PRIO => 'error' });
		return undef;
	    }	    
	    $self->renewalstate("sendrequest");
	} 
	elsif ($self->renewalstate() eq "sendrequest") 
	{
	    $self->log({ MSG => "State: sendrequest",
			 PRIO => 'debug' });
	    
	    if (! $self->sendrequest()) {
		$self->log({ MSG => "Could not send request",
			     PRIO => 'error' });
		return undef;
	    }
	}
	elsif ($self->renewalstate() eq "completed") 
	{
	    $self->log({ MSG => "State: completed",
			 PRIO => 'debug' });

	    # reset state
	    $self->renewalstate(undef);
	    last;
	}
	else
	{
	    $self->log({ MSG => "State unknown: " . $self->renewalstate(),
			 PRIO => 'error' });
	    return undef;
	}

    }

    return 1;
}



###########################################################################
# abstract methods to be implemented by the instances

# get main certificate from keystore
# caller must return a hash ref:
# CERTFILE => file containing the cert OR
# CERTDATA => string containg the cert data
# CERTFORMAT => 'PEM' or 'DER'
sub getcert {
    return undef;
}

# get private key for main certificate from keystore
# caller must return a hash ref containing the unencrypted private key in
# OpenSSL format
# Return:
# KEYDATA => string containg the PEM encoded private key data
sub getkey {
    return undef;
}

sub createrequest {
    return undef;
}

sub installcert {
    return undef;
}

# get all root certificates from the configuration
# return:
# arrayref of hashes containing:
#   CERTINFO => hash as returned by getcertinfo()
#   CERTFILE => filename
#   CERTFORMAT => cert format (PEM, DER)
sub getrootcerts {
    my $self = shift;
    my @result = ();

    foreach my $index (keys %{$self->{OPTIONS}->{ENTRY}->{rootcacert}}) {
	next if ($index eq "INHERIT");

	# FIXME: determine certificate format of root certificate
	my $certfile = $self->{OPTIONS}->{ENTRY}->{rootcacert}->{$index};
	my $certformat = 'PEM';
	my $certinfo = $self->getcertinfo(CERTFILE => $certfile,
					  CERTFORMAT => $certformat);
	if (defined $certinfo) {
	    push (@result, { CERTINFO => $certinfo,
			     CERTFILE => $certfile,
			     CERTFORMAT => $certformat,
			 });
	}
    }
    
    return \@result;
}

# build a certificate chain for this CA instance. the certificate chain
# will NOT be verified cryptographically.
# return:
# arrayref containing ca certificate information, starting at the
# root ca
# undef on error (e. g. root certificate could not be found)
sub buildcertificatechain {
    my $self = shift;
    
    my @trustedroots = @{$self->{STATE}->{DATA}->{ROOTCACERTS}};
    my @cacerts = @{$self->{STATE}->{DATA}->{SCEP}->{CACERTS}};

    my %rootcertfingerprint;
    foreach my $entry (@trustedroots) {
	my $fingerprint = $entry->{CERTINFO}->{CertificateFingerprint};
	$rootcertfingerprint{$fingerprint}++;
    }

    # output structure
    my @chain;

    my $ii = 0;
    my $rootindex;
    # determine root
    foreach my $entry (@cacerts) {
	my $fingerprint = $entry->{CERTINFO}->{CertificateFingerprint};

	if (exists $rootcertfingerprint{$fingerprint}) {
	    $self->debug("Root certificate identified: $fingerprint");
	    push (@chain, $entry);
	    $rootindex = $ii;
	    last;
	}
	$ii++;
    }

    if (!defined $rootindex) {
	$self->seterror("No matching root certificate was configured");
	return undef;
    }

    # remove root certs from candidate list
    @cacerts = grep(! exists $rootcertfingerprint{ $_->{CERTINFO}->{CertificateFingerprint} }, 
		    @cacerts);

    # build chain downwards from root certificate (unfortunate: would
    # be easier bottom-up)
    while ($#cacerts >= 0) {
	# get last element
	my $top = $chain[$#chain];
	my $parentsubjectname = $top->{CERTINFO}->{SubjectName};
	my $parentsubjectkeyid = $top->{CERTINFO}->{SubjectKeyIdentifier};
	
	my $noaction = 1;
	for ($ii = 0; $ii <= $#cacerts; $ii++) {
	    my $entry = $cacerts[$ii];

	    my $issuername = $entry->{CERTINFO}->{IssuerName};
	    my $authoritykeyid = $entry->{CERTINFO}->{AuthorityKeyIdentifier};
	    my $subjectkeyid = $entry->{CERTINFO}->{SubjectKeyIdentifier};

	    if (defined $authoritykeyid and $authoritykeyid =~ /^keyid:(.*)/) {
		if (($1 eq $parentsubjectkeyid) and
		    ($1 ne $authoritykeyid)) {
		    push (@chain, $entry);

		    # remove this cert from cert list
		    splice(@cacerts, $ii, 1);
		    $noaction = 0;
		    last;
		}
	    }
	    # FIXME: note: we only handle authoritykeyid chaining!
	    if ($issuername eq $parentsubjectname) {
		push (@chain, $entry);

		# remove this cert from cert list
		splice(@cacerts, $ii, 1);
		$noaction = 0;
		last;
	    }
	}
	if ($noaction) {
 	    $self->info("Not all certificates belong to the chain, may be incomplete\n");
	    last;
	}
    }
    
    return \@chain;
}

# cryptographically verify certificate chain
# TODO
sub verifycertificatechain {

    return 1;
}

# call an execution hook
sub executehook {
    my $self = shift;
    my $hook = shift;
    my %args = ( 
        @_,         # argument pair list
    );
    
    # hook not defined -> success
    return 1 unless defined $hook;
    
    $self->info("Running external hook function");
    
    if ($hook =~ /::/) {
	# execute Perl method
	$self->info("Perl method hook not yet supported");
	return undef;
    } 
    else {
	# assume it's an executable
	$self->debug("Calling shell hook executable");

	$args{'__LOCATION__'} = $self->{INSTANCE}->{OPTIONS}->{ENTRY}->{location} || $self->{OPTIONS}->{ENTRY}->{location};
	$args{'__ENTRY__'}    =  $self->{INSTANCE}->{OPTIONS}->{ENTRYNAME} || $self->{OPTIONS}->{ENTRYNAME};

	# replace values passed to this function
	foreach my $key (keys %args) {
	    my $value = $args{$key} || "";
	    $hook =~ s/$key/$value/g;
	}
	
	$self->info("Exec: $hook");
	return system($hook) / 256;
    }
}

# call external hook for notification event
sub notify {
    my $self = shift;
    my $notification = shift;
    my %args = ( 
        @_,         # argument pair list
    );
    
    return $self->executehook($self->{OPTIONS}->{ENTRY}->{hook}->{notify}->{$notification}, %args);
}



# obtain CA certificates via SCEP
# returns a hash containing the following information:
# RACERT => SCEP RA certificate (scalar, filename)
# CACERTS => CA certificate chain, starting at highes (root) level 
#            (array, filenames)
sub getcacerts {
    my $self = shift;

    # get root certificates
    # these certificates are configured to be trusted
    $self->{STATE}->{DATA}->{ROOTCACERTS} = $self->getrootcerts();

    my $scepracert = $self->{STATE}->{DATA}->{SCEP}->{RACERT};    

    return $scepracert if (defined $scepracert and -r $scepracert);

    my $sscep = $self->{OPTIONS}->{CONFIG}->get('cmd.sscep');
    my $cacertdir = $self->{OPTIONS}->{ENTRY}->{scepcertdir};
    if (! defined $cacertdir) {
	$self->seterror("scepcertdir not specified for keystore");
	return undef;
    }
    my $cacertbase = File::Spec->catfile($cacertdir, 'cacert');
    my $scepurl = $self->{OPTIONS}->{ENTRY}->{scepurl};
    if (! defined $scepurl) {
	$self->seterror("scepurl not specified for keystore");
	return undef;
    }

    # delete existing ca certs
    my $ii = 0;
    while (-e $cacertbase . "-" . $ii) {
	$self->debug("Unlinking " . $cacertbase . "-" . $ii);
	unlink $cacertbase . "-" . $ii;
	$ii++;
    }
    

    $self->info("Requesting CA certificates");
    
    my @cmd = (qq($sscep),
	       'getca',
	       '-u',
	       qq($scepurl),
	       '-c',
	       qq($cacertbase));
    
    $self->debug("Exec: " . join(' ', @cmd));
    if (system(join(' ', @cmd)) != 0) {
	$self->seterror("Could not retrieve CA certs");
	return undef;
    }
    
    $scepracert = $cacertbase . "-0";

    # collect all ca certificates returned by the SCEP command
    my @cacerts = ();
    $ii = 1;

    my $certfile = $cacertbase . "-$ii";
    while (-r $certfile) {
	my $certformat = 'PEM'; # always returned by sscep
	my $certinfo = $self->getcertinfo(CERTFILE => $certfile,
					  CERTFORMAT => 'PEM');

	if (defined $certinfo) {
	    push (@cacerts, { CERTINFO => $certinfo,
			      CERTFILE => $certfile,
			      CERTFORMAT => $certformat,
			  });
	}
	
	$ii++;
	$certfile = $cacertbase . "-$ii";
    }
    $self->{STATE}->{DATA}->{SCEP}->{CACERTS} = \@cacerts;

    # build certificate chain
    $self->{STATE}->{DATA}->{CERTCHAIN} = $self->buildcertificatechain();

    if (! defined $self->{STATE}->{DATA}->{CERTCHAIN}) {
	$self->seterror("Could not build certificate chain, probably trusted root certificate was not configured");
	return undef;
    }

    if (-r $scepracert) {
	$self->{STATE}->{DATA}->{SCEP}->{RACERT} = $scepracert;
	return $scepracert;
    }

    return undef;
}

sub sendrequest {
    my $self = shift;

    $self->info("Sending request");
    #print Dumper $self->{STATE}->{DATA};

    if (! $self->getcacerts()) {
	$self->seterror("Could not get CA certs");
	return undef;
    }

    my $requestfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{REQUESTFILE};
    my $keyfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{KEYFILE};
    my $pin = $self->{PIN} || $self->{OPTIONS}->{ENTRY}->{pin};
    my $sscep = $self->{OPTIONS}->{CONFIG}->get('cmd.sscep');
    my $scepurl = $self->{OPTIONS}->{ENTRY}->{scepurl};
    my $scepsignaturekey = $self->{OPTIONS}->{ENTRY}->{scepsignaturekey};
    my $scepracert = $self->{STATE}->{DATA}->{SCEP}->{RACERT};

    if (! exists $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{CERTFILE}) {
	my $certfile = $self->{OPTIONS}->{ENTRYNAME} . "-cert.pem";
	$self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{CERTFILE} = 
	    File::Spec->catfile($self->{OPTIONS}->{ENTRY}->{statedir}, 
				$certfile);
    }

    my $newcertfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{CERTFILE};
    my $openssl = $self->{OPTIONS}->{openssl_shell};
    
    
    $self->debug("request: $requestfile");
    $self->debug("keyfile: $keyfile");
    $self->debug("sscep: $sscep");
    $self->debug("scepurl: $scepurl");
    $self->debug("scepsignaturekey: $scepsignaturekey");
    $self->debug("scepracert: $scepracert");
    $self->debug("newcertfile: $newcertfile");
    $self->debug("openssl: $openssl");

    my @cmd;
    my $tmpkeyfile = $keyfile;
    if ($pin ne "") {
	# temporarily create an unencrypted copy of the RSA key (sscep
	# cannot handle encrypted RSA keys in batch mode)
	$tmpkeyfile = $self->gettmpfile();
	$self->debug("tmpkeyfile: $tmpkeyfile");
	chmod 0600, $tmpkeyfile;
	
	@cmd = (qq("$openssl"),
		'rsa',
		'-in',
		qq($keyfile),
		'-out',
		qq($tmpkeyfile),
		'-passin',
		'env:PIN',
		);

	$ENV{PIN} = $pin;
	if (system(join(' ', @cmd)) != 0) {
	    $self->seterror("Could not convert RSA key");
	    delete $ENV{PIN};
	    unlink $tmpkeyfile;
	    return undef;
	}
	delete $ENV{PIN};
    }


    my @autoapprove = ();
    my $oldkeyfile;
    my $oldcertfile;
    if ($scepsignaturekey =~ /(old|existing)/i) {
	# get existing private key (unencrypted, PEM format)
	my $oldkey = $self->getkey()->{KEYDATA};
	if (! defined $oldkey) {
	    $self->seterror("Could not get old key from certificate instance");
	    return undef;
	}

 	$oldkeyfile = $self->gettmpfile();
        chmod 0600, $oldkeyfile;
	local *HANDLE;
	if (!open HANDLE, ">$oldkeyfile") {
	    $self->seterror("Could not write temporary key file (old key)");
	    return undef;
	}
	print HANDLE $oldkey;
	close HANDLE;

	$oldcertfile = $self->gettmpfile();
	if (!open HANDLE, ">$oldcertfile") {
	    $self->seterror("Could not write temporary cert file (old certificate)");
	    return undef;
	}
	print HANDLE $self->{CERT}->{RAW}->{PEM};
	close HANDLE;

        @autoapprove = ('-K', 
			$oldkeyfile,
			'-O',
			$oldcertfile,
	    );
    }

    @cmd = (qq($sscep),
	    'enroll',
	    '-u',
	    qq($scepurl),
	    '-c',
	    qq($scepracert),
	    '-r',
	    qq($requestfile),
	    '-k',
	    qq($tmpkeyfile),
	    '-l',
	    qq($newcertfile),
	    @autoapprove,
	    '-t',
	    '5',
	    '-n',
	    '1',
	    );

    $self->debug("Exec: " . join(' ', @cmd));
    
    my $rc;
    eval {
	local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
	alarm 120;
	$rc = system(join(' ', @cmd)) / 256;
	alarm 0;
    };
    unlink $tmpkeyfile if ($pin ne "");
    unlink $oldkeyfile if (defined $oldkeyfile);
    unlink $oldcertfile if (defined $oldcertfile);

    $self->info("Return code: $rc");
    if ($@) {
	# timed out
	die unless $@ eq "alarm\n";   # propagate unexpected errors
	$self->info("Timed out.");
	return undef;
    }


    if ($rc == 3) {
	# request is pending
	$self->info("Request is still pending");
	return 1;
    }

    if ($rc != 0) {
	$self->seterror("Could not run SCEP enrollment");
	return undef;
    }

    if (-r $newcertfile) {
	# successful installation of the new certificate.
	# parse new certificate.
	# NOTE: in previous versions the hooks reported the old certificate's
	# data. here we change it in a way that the new data is reported
	my $newcert;
	$newcert->{INFO} = $self->getcertinfo(CERTFILE => $newcertfile,
					      CERTFORMAT => 'PEM');


	$self->executehook($self->{OPTIONS}->{ENTRY}->{hook}->{renewal}->{install}->{pre},
			   '__NOTAFTER__' => $self->{CERT}->{INFO}->{NotAfter},
			   '__NOTBEFORE__' => $self->{CERT}->{INFO}->{NotBefore},
			   '__NEWCERT_NOTAFTER__' => $newcert->{INFO}->{NotAfter},
			   '__NEWCERT_NOTBEFORE__' => $newcert->{INFO}->{NotBefore},
	    );

	my $rc = $self->installcert(CERTFILE => $newcertfile,
				    CERTFORMAT => 'PEM');
	if (defined $rc and $rc) {

	    $self->executehook($self->{OPTIONS}->{ENTRY}->{hook}->{renewal}->{install}->{post},
			       '__NOTAFTER__' => $self->{CERT}->{INFO}->{NotAfter},
			       '__NOTBEFORE__' => $self->{CERT}->{INFO}->{NotBefore},
			       '__NEWCERT_NOTAFTER__' => $newcert->{INFO}->{NotAfter},
			       '__NEWCERT_NOTBEFORE__' => $newcert->{INFO}->{NotBefore},
		);
	    
	    return $rc;
	}
	return undef;
    }
    
    return 1;
}


1;
