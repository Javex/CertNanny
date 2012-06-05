#!/usr/bin/perl
#
# CertNanny - Automatic renewal for X509v3 certificates using SCEP
# 2005-02 Martin Bartosch <m.bartosch@cynops.de>
#
# This software is distributed under the GNU General Public License - see the
# accompanying LICENSE file for more details.
#

use strict;
use warnings;
use English;

use File::Spec;

use Pod::Usage;
use Getopt::Long;

use FindBin;
use lib "$FindBin::Bin/../lib/perl";

use CertNanny;
$OSNAME = "Not Windows";
if ($OSNAME eq "MSWin32") {
    require Win32;
    Win32->import();
    require Win32::Daemon;
    Win32::Daemon->import();
} else {
	foreach my $name qw(SERVICE_STOPPED SERVICE_START_PENDING SERVICE_STOP_PENDING SERVICE_PAUSE_PENDING SERVICE_PAUSED SERVICE_CONTINUE_PENDING SERVICE_RUNNING SERVICE_CONTROL_NONE SERVICE_CONTROL_INTERROGATE SERVICE_CONTROL_SHUTDOWN) {
		no strict;
		# declare a dummy function for symbols listed in Win32(::Daemon)
		*{$name} = sub { 1; };
		use strict;
	}
}


###########################################################################
# main


my %config;

my $msg = "CertNanny, version $CertNanny::VERSION";
GetOptions(\%config,
	   qw(
	      help|?
	      man
	      cfg|cfgfile|conf|config=s
			win_user=s
			win_password=s
	      )) or pod2usage(-msg => $msg, -verbose => 0);

pod2usage(-exitstatus => 0, -verbose => 2) if $config{man};
pod2usage(-msg => $msg, -verbose => 1) if ($config{help} or
		 (! exists $config{cfg}));

die "Could not read config file $config{cfg}. Stopped" 
    unless (-r $config{cfg});

my $monitor = CertNanny->new(CONFIG => $config{cfg});

foreach my $cmd (@ARGV) {
	if ($OSNAME eq 'MSWin32') {
		# Windows Service related commands
		my $servicename = $monitor->get_config_value("platform.windows.servicename") || "CertNanny";
		if ($cmd eq "install") {
			my $cfgpath = $config{cfg};
			my $servicepath= File::Spec->catfile($FindBin::Bin, $FindBin::Script);
			
			my $ret = Win32::Daemon::CreateService({
				machine =>  '',
				name    =>  $servicename,
				display =>  $servicename,
				path    =>  $EXECUTABLE_NAME,
				user    =>  $config{win_user} || "",
				pwd     =>  $config{win_password} || "",
				description => 'Automatic certificate renewal',
				parameters =>qq{"$servicepath" --cfg "$cfgpath"},
			});
			
			if ($ret) {
				print "Service successfully added.\n";
				exit 0;
			} else {
				print "Failed to add service: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n";
				exit 1;
			}
		} elsif ($cmd eq "uninstall") {
			if (Win32::Daemon::DeleteService('',$servicename)) {
				print "Service successfully uninstalled.\n";
				exit 0;
			} else {
				print "Failed to uninstall service: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n";
				exit 1;
			}
		}
	}
	
	
	$monitor->$cmd(%config) || die "Invalid action: $cmd. Stopped";
}
if (scalar @ARGV > 0) {
   # if we had commands as arguments, we're done, else we are a service and do a lot of stuff below :)
	exit;
}

if ($OSNAME eq 'MSWin32') {
  open my $LOG, '>>', 'c:\temp\debug.txt';
  print $LOG "SERVICE_STOPPED = " . SERVICE_STOPPED() . "\n";
  print $LOG "SERVICE_START_PENDING = " . SERVICE_START_PENDING() . "\n";
  print $LOG "SERVICE_STOP_PENDING = " . SERVICE_STOP_PENDING() . "\n";
  print $LOG "SERVICE_PAUSE_PENDING = " . SERVICE_PAUSE_PENDING() . "\n";
  print $LOG "SERVICE_CONTINUE_PENDING = " . SERVICE_CONTINUE_PENDING() . "\n";
  print $LOG "SERVICE_STOP_PENDING = " . SERVICE_STOP_PENDING() . "\n";
  print $LOG "SERVICE_RUNNING = " . SERVICE_RUNNING() . "\n";
   my $State="";
   my $PrevState = SERVICE_START_PENDING();
  
	#start service
   if(Win32::Daemon::StartService())
   {
       print "Successfully started.\n";
   }
   else
   {
       print "Failed to start service: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n";
      exit; 
   }
  
  my $starttime=0;
  
  my $SERVICE_SLEEP_TIME = 1000; # 1 second


  while( SERVICE_STOPPED() != ( $State = Win32::Daemon::State() ) )
  {

    print $LOG "state: " . $State . "\n";
    
    # if ($State == 0 ) {
#	    Win32::Daemon::State( SERVICE_RUNNING() );
#	    $PrevState = SERVICE_RUNNING();
    #   }

    if( SERVICE_START_PENDING() == $State )
    {
      # Initialization code
      
      Win32::Daemon::State( SERVICE_RUNNING() );
      $PrevState = SERVICE_RUNNING();
      next;
    }
    elsif( SERVICE_STOP_PENDING() == $State )
    {
      Win32::Daemon::State( SERVICE_STOPPED() );
      next;
    }
    elsif( SERVICE_PAUSE_PENDING() == $State )
    {
      # "Pausing...";
      Win32::Daemon::State( SERVICE_PAUSED() );
      $PrevState = SERVICE_PAUSED();
      next;
    }
    elsif( SERVICE_CONTINUE_PENDING() == $State )
    {
      # "Resuming...";
      Win32::Daemon::State( SERVICE_RUNNING() );
      $PrevState = SERVICE_RUNNING();
      next;
    }
    elsif( SERVICE_STOP_PENDING() == $State )
    {
      # "Stopping...";
      Win32::Daemon::State( SERVICE_STOPPED() );
      $PrevState = SERVICE_STOPPED();
      next;
    }
    elsif( SERVICE_RUNNING() == $State )
    {
      my $currtime=time;	    

      print $LOG "currtime: " . $currtime . "\n";

      if($currtime >= $starttime)
      {
	        print $LOG "currtime > starttime\n";
	  	# reinstantiate CertNanny object (make sure that destructor gets called)
		$monitor = CertNanny->new(CONFIG => $config{cfg});
		print $LOG "new monitor object\n";
		# The service is running as normal...
		# ...add the main code here...
		$monitor->redirect_stdout_stderr();
		print $LOG "stdout/stderr redirect\n";

		my $rc;
		eval {
			$rc = $monitor->renew();
		};
		print $LOG "EVAL_ERROR? " . $EVAL_ERROR;
	        print $LOG "renew was called: $rc\n";

	 
		#if the renewal was successful the starttime will be increased by one day (86400 seconds -> 24hours -> 3600 seconds per hour)
		my $timeframe = $monitor->get_config_value("platform.windows.serviceinterval", "FILE") || 86400;
		$starttime=$currtime+$timeframe;  
      }      
      print $LOG "before sleep ...\n";
      Win32::Sleep( $SERVICE_SLEEP_TIME );
      print $LOG "calling next ...\n";
      next;
    }
    else
    {
      # Got an unhandled control message. Set the state to
      # whatever the previous state was.
      Win32::Daemon::State( $PrevState );
      next;
    }

    print $LOG "before outstanding commands checking ...\n";
        # Check for any outstanding commands. Pass in a non zero value
        # and it resets the Last Message to SERVICE_CONTROL_NONE.
	eval {
   	my $Message = Win32::Daemon::QueryLastMessage(1);
	};
	print $LOG "EVAL_ERROR? " . $EVAL_ERROR;


        if( SERVICE_CONTROL_NONE() != ( my $Message = Win32::Daemon::QueryLastMessage( 1 ) ) )
        {
	
    	  print $LOG "Message: $Message ...\n";
          if( SERVICE_CONTROL_INTERROGATE() == $Message )
          {
            # Got here if the Service Control Manager is requesting
            # the current state of the service. This can happen for
            # a variety of reasons. Report the last state we set.
            Win32::Daemon::State( $PrevState );
          }
        elsif( SERVICE_CONTROL_SHUTDOWN() == $Message )
        {
          # Yikes! The system is shutting down. We had better clean up
          # and stop.
          # Tell the SCM that we are preparing to shutdown and that we expect
          # it to take 25 seconds (so don't terminate us for at least 1 second)...
	  Win32::Daemon::State( SERVICE_STOP_PENDING(), 1000 );
        }
      }
      # Snooze for awhile so we don't suck up cpu time...
      print $LOG "before sleep ...\n";
      Win32::Sleep( $SERVICE_SLEEP_TIME );
      print $LOG "calling next ...\n";
      next;
   }
   
   # We are done so close down...
   Win32::Daemon::StopService();
}

__END__

    
=head1 NAME

    
certnanny - Certificate monitoring and renewal client
   
=head1 SYNOPSIS
    
certnanny --cfg=<configfile> [options] <action>
    
Options:

  --help            brief help message
  --man             full documentation

  --cfg             specify config file to use
  --win_user        specify alternative Windows username to run the Windows Service
  --win_password    specify password corresponding to win_user

Actions:

  check             Check all configured keystores
  renew             Run automatic renewal on all configured keystores
  install           Install CertNanny as a Windows Service (applicable only on Windows platforms)
  uninstall         Uninstall CertNanny service (applicable only on Windows platforms)
    
=head1 OPTIONS

=over 8

=item B<--help>
 
Print a brief help message and exits.
 
=item B<--man>
 
Prints the manual page and exits.

=item B<--cfg> file
 
Uses the specified file for configuration. Mandatory.

=back

=head1 ACTIONS

=over 8

=item B<check>
 
Check the configured keystores and print out warning if the expiry time
is within the configured warning interval.

=item B<renew>
 
Check the configured keystores and schedule automatic renewal.
Can be repeated as many times as desired and will automatically keep
the correct state.

=item B<install>

Install CertNanny as a Win32 Service. CertNanny will appear on the Windows Services list and can now be started, restarted or stopped. After installing, CertNanny Service has to be started manually or gets started automatically after reboot. As a windows service, CertNanny runs only in renew mode.

=item B<uninstall>

Uninstall CertNanny Win32 Service. Removes CertNanny froom the Windows Services list. 

=back
 
=head1 DESCRIPTION
 
B<certnanny> will process all configured keystores and automatically
run a SCEP renewal on them.

=head1 DOCUMENTATION

=head1 Copyright and License

CertNanny

Automatic renewal for X509v3 certificates using SCEP

Copyright (c) 2005, 2006 Martin Bartosch <m.bartosch@cynops.de>

CertNanny implements a framework for certificate renewal automation.

This software is distributed under the GNU General Public License - see the
accompanying LICENSE file for more details.


=head1 Abstract

CertNanny is a client-side program that allows fully automatic
renewal of certificates. The basic idea is to have a number of local
keystores that are monitored for expiring certificates. If a certificate
is about to expire, the program automatically creates a new certificate
request with the existing certificate data, enrolls the request with the
configured CA and polls the CA for the issued certificate. Once the
certificate is ready, a new keystore with the new certificate is composed
and replaces the old keystore.



=head1 Distribution Overview

Refer to this README in order to learn how CertNanny works and for a
configuration reference.
Read the INSTALL file on how to install the software.
The QUICKSTART file contains a step-by-step description on how to get 
the software up and running quickly.
Please check the FAQ if you have questions not covered here.


=head1 1 Introduction

=head2 1.1 The problem

Digital Certificates conforming to the X.509 standard contain an
explicit validity range that states "NotBefore" and "NotAfter" dates.
The certificate is only valid beween these two dates, and applications
using the certificates must check the certificate's validity whenever
using it for communication purposes.

The validity range serves a useful purpose: it administratively limits
the time a cryptographic key is used and allows the issuing CA to exert
control on the time the certificate as a security credential is used.
Both are useful and valuable means to enforce the PKI's policy, but
it also poses a risk on business continuity. If a certificate expires
without being replaced with a "fresh" certificate, communication ceases
to work and causes service downtime.

System administrators must address this problem by replacing the 
certificate prior to expiration. This adds to the common workload
and usually tends to be forgotten, leading to production problems
after expiry.
Another approach is to use very long validity periods, but this is
often not desirable in environments with strict policies.


=head2 1.2 The solution

CertNanny addresses this common problem in PKI-enabled client 
applications. CertNanny is designed to be invoked automatically
(e. g. once a day) on a client system that uses Digital Certificates.
It checks all certificate keystores configured for the system for
certificates that are about to expire within a certain time frame.

The most important design decision for this process is that all 
activities are initiated on the client system. The PKI system does 
not actively monitor certificate lifetime and does not inform any 
party about expiring certificates, hence the client must do most of
the work itself.


=head3 1.2.1 Assumptions and prerequisites

On a client system certificates are stored in Keystores. A keystore 
holds a private key, the end entity certificate, the issuing CA 
certificate and the CA certificate chain up to the trusted Root CA. 

Common keystore types are

=over 

=item * 

MQ keystores to be used for MQ SSL

=item * 

Java Keystores to be used for Java programs

=item * 

OpenSSL "keystores", a raw PEM encoded certificate and an encrypted RSA key

=back

Root Certificates are usually distributed to the machines via the usual 
deployment mechanisms that are used for software distribution in the
target environment. For security reasons the distribution of Root 
Certificates is not in the scope of the automatic renewal process itself. 

CertNanny may provide means for automatic and secure deployment of 
root certificates in the future that may be used instead of the usual 
deployment procedures.

The machine in question must be able to establish a http connection to 
the PKI systems.


=head3 1.2.2 Local setup

A new software component must be installed on the system. This software 
component takes care of renewing the configured keystores. 
The administrator must configure all keystores to monitor on the local 
system. An arbitrary number of keystores can be configured to be 
monitored and will be automatically monitored.

Required configuration settings for each keystore to monitor:

=over

=item * 

Keystore location

=item * 

Keystore type

=item * 

Number of days prior to expiration for automatic renewal trigger

=item * 

Warning threshold (number of days prior to expiration), if this 
threshold is reached the script can send an error to a monitoring 
system to inform an administrator that the automatic renewal has 
not succeeded.

=item * 

Renewal URL (SCEP URL)

=back

The CertNanny script should be invoked in 'renew' mode at least 
once a day, e. g. via cron.

On Win32 platforms the CertNanny script can be installed as a
Windows service via the <install> option.

The CertNanny script may be invoked in 'check' mode that will only 
check if the configured keystores are valid for more than a configured 
amount of time (may be used for monitorin integration).

If the readonly warning time is configured a few days shorter than the 
automatic renewal period, the system has some time to perform the 
actual renewal of the new keystore. If for some reason the new keystore 
is not installed within the planned time period, the alarm still comes 
early enough to allow investigation of the cause before it becomes a 
real production problem.


=head3 1.2.3 Normal operation (fully automatic renewal mode)

The CertNanny script is invoked once a day and checks the remaining 
validity of the configured keystores. Usually the certificates are 
valid longer than the configured threshold for automatic renewal. 
In this case the script will terminate without performing any action.

If the script detects that a certificate must be renewed it starts the 
renewal process. (The renewal process itself is stateful and is resumed 
in the correct state on each subsequent invocation of the CertNanny 
script until the process has been completed.)

=over

=item *

(1) certificate is found to be valid for less than <n> days

=item *

fetch current CA certificates from the PKI

=item *

verify CA certificates against the locally available set of acceptable Root
Certificates

=item *

(2) extract the certificate subject data (Common Name, SubjectAlternativeNames)

=item *

using this data create a new prototype keystore and a new certificate request
for this data

=item *

(3) send the certificate request to the CA

=item *

query the CA for a new certificate that was issued for this request

=back

At this point the initial request usually terminated with a 'pending' 
response from the CA. For any subsequent invocation of the script 
step (3) is repeated until the CA replies with the new certificate:

=over

=item *

CA delivers new certificate to the client system

=item *

script verifies signature of delivered certificate and verifies the complete
certificate chain up to the Root CA

=item *

the certificate is installed into the prototype keystore

=item *

all intermediate CA certificates including the corresponding Root CA
certificate are installed in the prototype keystore as well

=item *

(4) an optional pre-install script or Perl Method is invoked, allowing to
prepare the system for replacement of the old keystore

=item *

(5) the old keystore is backed up, the new keystore is installed in place of
the old one

=item *

(6) an optional post-install script or Perl Method is invoked, allowing to
activate the changes, notify an administrators or similar.

=back

=head3 1.2.4 Semi-automatic (sandboxed) renewal mode

The procedure described above assumes that the new keystore directly 
replaces the old one. Depending on the employed policy this may not 
be desired, if it is e. g. required that absolutely no (automatic) 
change to the production system happens without human interaction, 
the script can easily be configured in the following way:

=over

=item *

let the script operate on a copy of the production keystore that is placed in a
"sandbox" area

=item *

automatically request a new certificate from this keystore once the time has
come to do so

=item *

create a new keystore in the sandbox area from the new certificate (no access
to production data yet)

=item *

run a notification command (e. g. monitoring event or email) in the
post-install step of the renewal that informs an administrator that a new
keystore has been created in the sandbox

=item *

the administrator must then manually copy the new keystore from the quarantine
area to production within the remaining life time of the old certificate

=back

=head3 1.2.5 Contents of the automatically created keystore

The entire keystore is recreated by the renewal process. In particular 
this means: End entity certificate (provided by CA) and corresponding 
private key (created locally) plus all CA certificates up to the 
Root CA (also called the Certificate Chain). During the automatic 
renewal process these CA certificates are sent to the requesting party. 
The script picks up these certificates and also verifies the Root 
Certificate sent by the CA against a locally configured list of 
Root Certificates. This list of trusted Root Certificates must be 
updated out-of-band by e. g. an automated deployment procedure.
(Also see appendix.)

After downloading the new certificate the script builds the 
certificate chain and adds it to the resulting key store. 


=head3 1.2.6 Implementation

The script itself is written in Perl. It uses OpenSSL for crypto operation 
and the sscep program for communicating with the PKI systems.

On Win32 platforms you also need CAPICOM and Win32 Deamon.


=head3 1.2.7 Features and status

=over

=item *

Multi-platform support

  * Tested and supported:
  - Linux
  - Solaris
  - AIX
  - Darwin (Mac OS X)
  - NonStop/Tandem via (OSS)
  - Windows

  * Planned:
  - z/OS

=item *

Multi-keystore support: modular design allows to extend the system for
supporting the certificate keystore of a number of applications

  * Supported (RSA keys only):
  - OpenSSL (PEM encoded certificate and key in separate files, suitable
    e. g. for Apache/mod_ssl web servers)
  - MQ Keystore (IBM GSKit)
  - PKCS #8
  - Java Keystore
  - Windows Certificate Store
  - PKCS#12

  * Planned:
  - RACF (z/OS; USS access to RACF via REXX)
  - Java Keystore with nCipher HSM module support
  - OpenSSL keystore with nCipher HSM module support
  - Non RSA keys

=item *

Client-side installation philosophy (no intelligence on the PKI side, the
client decides when it is time to renew a certificate)

=item *

Uses standard SCEP protocol for certificate enrollment and download

=item *

Optional automatic approval of new certificate requests with existing private
key (requires SCEP server compliant to newer SCEP drafts)

=back


=head2 1.3 The tools

The CertNanny system itself is written in Perl (5.6.1 or higher). Apart
from the Perl Interpreter the following program binaries are required:

=over

=item *

openssl

=item *

sscep

=item *

CAPICOM (only for Win32)

=item *

Win32 Daemon (only for Win32)

=back

Read the INSTALL document for comments about building these tool programs
for your platform.


=head1 2 Configuration

CertNanny requires a configuration file that must be specified for
each invocation. This makes it possible to have multiple configuration 
files on the same system, each referencing a different set of certificate 
keystores to monitor.

A CertNanny configuration file is a text file that contains key/value 
pairs.

Comment lines are indicated by a '#' symbol (only at the beginning of the 
line, otherwise they are considered to be part of the value itself).

A sample configuration file is included in etc/certnanny.cfg. New
users should use this file and adapt the settings to their setup:

=over

=item *

modify the config to use the correct paths for your local setup (Don't worry if
you don't have gsk6cmd, this is only required if you intend to renew IBM GSK
keystores.)

=item *

define at least one keystore to monitor (the default config does not include
any)

=item *

IMPORTANT: define at least one Root Certificate to use in your setup:

keystore.DEFAULT.rootcacert.1 = ...

=back

=head2 2.1 Common section

=head3 2.1.1 Binaries

In this section the explicit paths to the external binary tools are
configured. 

=over

=item cmd.openssl

Location of the OpenSSL binary (required)

Example: /usr/bin/openssl

=item cmd.sscep

Location of the SSCEP binary (required)

Example: /usr/local/bin/sscep

=item cmd.gsk6cmd

Location of the gsk6cmd binary (optional, used for IBM GSK Keystores only)

Example: /usr/bin/gsk6cmd

=item cmd.java

Location of the java binary (optional, used for Java keystores only)

Example: /opt/bin/java

=item cmd.keytool

Location of the java keytool binary (optional, used for Java keystores only)

Example: /opt/bin/keytool

=back 


=head3 2.1.2 Paths

=over

=item path.tmpdir

Path specification of a temporary directory (required)

Example: /tmp

=item path.libjava

TODO

=item cmd.gsklib

Location of the GSKit lib directory (optional, only required for GSKit
keystores on the Windows platform).

Example: c:\Program Files\IBM\gsk7\lib

=back

=head3 2.1.3 Other settings

=over

=item loglevel

Loglevel (optional)

Values: 0: fatal, 1: error, 2: notice, 3: info, 4: debug, 5: scep verbose, 6: scep debug

Example: 3

=item platform.windows.servicename

Defines the Windows Service name (optional).

Default: CertNanny

=item platform.windows.serviceinterval

Sets the time frame for starting the renewal process in seconds (optional). Should be set to at least one day (86400 seconds).

Default: 86400 

=back


=head2 2.2 Keystore section

The keystore section defines all certificate keystores that should be
checked and/or renewed by CertNanny. To make keystore definition
more flexible, the following features are available:

=over

=item *

Multiple keystores can be defined within the configuration file.  CertNanny
sequentially checks all configured keystores and may use different settings
(and even a different CA) for each configured keystore.

=item *

Default values can be specified that may be explicitly overridden by a specific
setting of a keystore. Using inheritance the Default mechanism can even be used
in a chain of inherited keystore definitions.

=item *

Other already defined configuration variables (within the same configuration
file) can be referenced.

=back

All keystore specific settings start with 'keystore.':

keystore.LABEL.SETTING = VALUE

The keystore settings for one specific keystore instance are bound 
together via a common identifier, the keystore LABEL. The LABEL is 
a alphanumeric string that must be identical for all settings that belong 
the the same keystore. It is recommended to use a name that identifies 
the purpose of the keystore. All settings with the same LABEL belong
to the same keystore.
Any number of different LABELs can be used to specify an arbitrary number
of distinct keystores.


=head3 2.2.1 Common keystore configuration settings

=over

=item platform.windows.servicename

Name of the Windows service to be installed by cernanny-service.pl. 

Default: Certnanny

=item logfile

Path name of the Certnanny logfile. The file will be overwritten on each invokation of CertNanny.

Default: stderr

=item platform.windows.serviceinterval

Time interval (in seconds) between renewal checks done by the Win32 service. Only necessary on Win32 platforms, on other platforms use cron or similar.

Default: 84600 (once per day)

=item keystore.LABEL.autorenew_days

Number of days prior to expiry the automatic renewal should start.

Default: 30

=item keystore.LABEL.warnexpiry_days

Number of days prior to expiry a warning message should be generated.

Default: 20

=item keystore.LABEL.scepsignaturekey

Renewal mode. Specifies which key to use for signing the SCEP request.  Newer
SCEP drafts allow to sign the request with an already existing key (e. g. of an
existing certificate). The SCEP server may automatically approve the SCEP
request when receiving a request signed with a valid certificate with the same
DN and of the same issuing CA.  Requires a patched sscep binary (patches
available in the distribution)

Default: new

Example: old

=item keystore.LABEL.scepurl

URL of the SCEP Server to use

Example: http://scep.ca.example.com/cgi-bin/scep

=item keystore.LABEL.scepcertdir

SCEP CA certificate directory. Specify a directory where CertNanny may place CA
certificates downloaded from the CA.

=item keystore.LABEL.statedir

SCEP keystore state directory. Specify a directory where CertNanny may create
temporary files associated with the keystore (i. e. private key, temporary
keystore and enrollment state) May be the same as scepcertdir.

=item keystore.LABEL.excludeexpiredrootcerts

Policy setting that determines if expired Root Certificates referenced
in the configuration should be included in newly created keystores.
It is recommended to exclude expired Root Certificates in order to avoid
problems with certain keystore types (notably MQ/GSKit).

Default: yes

Example: no


=item keystore.LABEL.excludenotyetvalidrootcerts

Policy setting that determines if not yet valid Root Certificates referenced
in the configuration should be included in newly created keystores.
It is recommended to include not yet valid Root Certificates to allow for
seamless CA rollover.

Default: no

Example: yes


=item keystore.LABEL.rootcacert.1

=item keystore.LABEL.rootcacert.2 

=item keystore.LABEL.rootcacert.3

=item (...)

Acceptable Root CA Certificates in PEM format. When creating a new keystore,
CertNanny must create a certificate chain that includes the issuing Root CA.
For security reasons, the Root CA Certificate that is sent via SCEP cannot be
trusted. Instead the Root CA Certificates must be deployed out-of-band and
explicitly configured for each keystore.  It is possible to specify an
arbitrary number of Root CA certificates here.

The Root CA certificates do not need to be related, they can span entirely
different CA hierarchies, making it possible to either encompass multiple PKIs
or allow for automatic Root CA key rollover.  It is not useful (but does not
harm) to include non-root CA certificates here, they are simply not considered
by the program.  The first Root CA certificate must have the index 1.
Subsequent entries are only read if the index numbers are adjacent.

=back

=head4 Hook definitions

A hooks is called whenever a certain event occurs. Hooks allow to call
external programs that interact with the client system, making it e. g.
possible to restart the client application once a new keystore is
available.

All Hook definitions expect the specification of an executable (binary
or shell script) that can be provided with arbitrary arguments.
Certain placeholders are available that are replaced with the current
value.
The following placeholders are available for all hooks:

=over

=item __ENTRY__

is replaced with the keystore's LABEL used in the config file

=item __LOCATION__ 

is replaced with the keystore location as defined in the config file

=back

=over

=item keystore.LABEL.hook.renewal.install.pre

=item keystore.LABEL.hook.renewal.install.post

Specifies an executable that is called whenever a certificate enrollment has
been completed and the prototype keystore has been created.  The 'pre' hook is
called imediately before the keystore specified in the config file is replaced.
The 'post' hook is called imediately after the keystore specified in the config
file has been replaced.  Within the program arguments the following
placeholders are recognized:

=over

=item __NOTBEFORE__

=item __NOTAFTER__

=item __NEWCERT_NOTBEFORE__

=item __NEWCERT_NOTAFTER__ 

these tags are replaced with the NotBefore/NotAfter dates
in the old certificate (__NOTBEFORE__, __NOTAFTER__) and the renewed
certificate (__NEWCERT_NOTBEFORE__, __NEWCERT_NOTAFTER__)

=back

=item keystore.LABEL.hook.renewal.state

Specifies an executable that is called whenever the internal status of the
keystore changes.  Within the program arguments the following placeholders are
recognized:

=over

=item __STATE__

is replaced with the new state. The following states are defined:

    initial     (first invocation)
    sendrequest (private key has been created)
    completed   (keystore has been replaced successfully)

=back

=item keystore.LABEL.hook.notify.warnexpiry

  Specifies an executable that is called whenever the warnexpiry_days
  threshold of the keystore is exceeded.

=over

=item __NOTBEFORE__

=item __NOTAFTER__ 

these tags are replaced with the NotBefore/NotAfter dates of the certificate

=back

=back

=head3 2.2.2 Keystore specific settings

=head4 2.2.2.1 OpenSSL Keystore

The keystore format covers certificates that are present in raw PEM or
DER encoded format. It supports OpenSSL and PKCS #8 private keys encoded
in PEM and DER format.

=over

=item keystore.LABEL.type = OpenSSL

  Mandatory, must literally be set to OpenSSL

=item keystore.LABEL.format

Certificate and key encoding. When installing the *new* certificate the
resulting key and certificates (including CA certificates) will be 
encoded in this format.

May be overridden specifically for key, CA certificates or Root certificates
by using the .keyformat, .cacertformat or .rootcacertformat options.
The software will autodetect if the *existing* cert/key is stored in a 
different format and use this data properly, but the *new* certificate/key 
will be written in format specified here, no matter how the original was 
encoded.

Allowed values: PEM, DER

Default: PEM

Example: DER

=item keystore.LABEL.location

Specifies the file name (location) of the PEM or DER encoded certificate 
to monitor.

When reading the certificate the software will automatically detect 
encoding (PEM/DER), regardless of the 'format' setting. See 'format'.

Example: /etc/apache/ssl.crt/server.crt

=item keystore.LABEL.keyfile

Specifies the location of the private key for the certificate.
The software will automatically detect encoding (PEM/DER), regardless
of the 'format' setting. See 'format'.

Example: /etc/apache/ssl.key/server.key

=item keystore.LABEL.keyformat

This setting is only evaluated when installing the new keystore.
Overrides the .format setting when installing the key specified with
.keyfile

Allowed values: PEM, DER

Default: value specified with .format

Example: 
    keystore.LABEL.format = DER
    keystore.LABEL.keyformat = PEM

=item keystore.LABEL.keytype

Specifies the private key format. Allowed values: OpenSSL, PKCS8

Default: OpenSSL

Example: PKCS8

=item keystore.LABEL.pin

Specifies the private key pin used to decrypt the private key. May
be empty (unencrypted key).

=item keystore.LABEL.cacert.0

=item keystore.LABEL.cacert.1

=item keystore.LABEL.cacert.2

=item . . . 

This setting is only evaluated when installing the new keystore.
Specifies the file name of the CA certificates forming the complete
certificate chain for the new end entity certificate.
Existing files will be backed up to the original filename contacenated
with '.backup'. Existing backups will be overwritten.

The .0 certificate will contain the topmost (Root) Certificate, 
subsequent entries (.1, .2 and so on) will contain increasingly deeper 
levels of the CA certificate hierarchy.

The enumeration may start with .0 or with .1 (in case you don't wish
to save the root certificate to a file). Processing stops if the
next expected integer index is not used.

If the CA certificate chain contains more certificates than specified
here only the specified levels will be written to files.
If the CA certificate chain contains less certificates than specified
here the additionally referenced files will not be created.

Example: 
    keystore.LABEL.cacert.0 = /etc/apache/ssl.crt/rootca.crt
    keystore.LABEL.cacert.1 = /etc/apache/ssl.crt/level2ca.crt

=item keystore.LABEL.cacertformat

This setting is only evaluated when installing the new keystore.
Overrides the .format setting when installing the CA certificates specified 
with .cacert.n

Allowed values: PEM, DER

Default: fall back to value specified with .format

Example: 
    keystore.LABEL.format = DER
    keystore.LABEL.cacertformat = PEM

=item keystore.LABEL.rootcacertbundle

This setting is only evaluated when installing the new keystore.
Specifies a target file containing a concatenation of all Root 
certificates specified with keystore.LABEL.rootcacert.x in the 
configuration file.

The file will be overwritten and newly created during installation of
the new keystore.

May only be specified if .rootcacertformat (or .format) is set to PEM.

Default: none

Example:
    keystore.LABEL.rootcacertformat = PEM
    keystore.LABEL.rootcacertbundle = /etc/apache/ssl.crt/ca-bundle.crt

=item keystore.LABEL.rootcacertdir

This setting is only evaluated when installing the new keystore.
Directory (or file template) for storing Root CA certificates specified 
in the config file.

If an existing directory is specified, all Root CA certificates specified 
in the configuration file will be written to this directory. The filenames
will be rootca-N.pem or rootca-N.der, depending on the certificate format
selected with .format or .rootcacertformat.
N is replaced with an integer number, yielding root-1.pem, root-2.pem etc.
Existing files with the same names will be overwritten.

If the specified path is NOT an existing directory, the last path component
of the specified path is interpreted as a template name for the Root
certificates. The path components leading to this template name are
interpreted as the directory specification.

If this directory exists (and is writable) the Root certificates
will be written to the file system using the specified
filename template. The filename template MUST include a '%i' that is
replaced with the index number of the Root certificate written. (If
no %i is included in the template name, only the last configured Root
certificate will be written to this filename).

The certificate file format is determined by .format or .rootcacertformat.
Existing files with the resulting names will be overwritten.

Default: none

Example: 
    keystore.LABEL.rootcacertdir = /etc/apache/ssl.crt/
    keystore.LABEL.rootcacertdir = /etc/apache/ssl.crt/trustedroot_%i.crt

=item keystore.LABEL.rootcacertformat

This setting is only evaluated when installing the new keystore.
Overrides the .format setting when installing the Root CA certificates 
specified with .rootcacertbundle or .rootcacertdir
Note that a Root CA certificate bundle can only be created in PEM format.

Allowed values: PEM, DER

Default: fall back to value specified with .format

Example: 
    keystore.LABEL.format = DER
    keystore.LABEL.rootcacertformat = PEM

=back

=head4 2.2.2.2 MQ Keystore

The MQ Keystore backend can be used to create keystores that work
with IBM MQ Series for AIX and Solaris (tested: Version 5.3). It requires 
the external command gsk6cmd from the MQ software distribution.

The driver ensures that the end entity certificate uses the same label
in the keystore which is important for the MQ manager process as it
uses the Queue name to access the correct entry in the keystore
(ibmwebspheremq*).

The Keystore driver requires the .sth file for the specified keystore
in order to access the private key in the .kdb key database. The .sth
file must be present in the same directory as the .kdb file.

=over

=item keystore.LABEL.type = MQ

Mandatory, must be literally set to MQ

=item keystore.LABEL.location

Base name of the MQ keystore to be used, i. e. the full path name
of the keystore without the .kdb extension.

=item keystore.LABEL.labelmatch = ibmwebspheremq.*

Regular expression describing the certificate label in the keystore
to monitor and renew. Only the first matching certificate will be 
renewed.

Renewed keystores will contain only one single end entity certificate
with the same label name as found as in the previous keystore.

=back

=head4 2.2.2.3 Java Keystore

The Java Keystore backend can be used to renew certificate stores, which are 
managed with the Java keytool command. This includes the native JKS format,
but also other formats for which a crypto service provider exists. The backend 
requires that a JRE (including the keytool and java commands) is installed. 

=over

=item keystore.LABEL.type = Java

Mandatory, must be literally set to Java

=item keystore.LABEL.location

Mandatory, specifies the file name of the Java keystore

Example: keystore.LABEL.location = $(prefix)/keystore.jks

=item keystore.LABEL.pin

Mandatory, the store password (keytool -storepass). Keytool requires at 
least 6 characters.

Example: keystore.LABEL.pin = 3kx6KQ7c

=item keystore.LABEL.keypin

Optional, the key password (keytool -keypass). 

Default: keystore.LABEL.pin.

Example: keystore.LABEL.keypin = 3kx6KQ7c

=item keystore.LABEL.alias

Optional, the alias (keytool -alias) of the key to monitor/renew. 
If not defined, the keystore must contain exactly one key.

Default: Automatically determined from the keystore. 

Example: keystore.LABEL.alias = mycert
  
=item keystore.LABEL.provider = sun.security.provider.Sun

Optional, the Java cryptography provider class name (keytool -provider)

Default: sun.security.provider.Sun

Example: 
    keystore.LABEL.provider = org.bouncycastle.jce.provider.BouncyCastleProvider

=item keystore.LABEL.format 

Optional, the Java keystore format (keytool -storetype).

Default: jks

Example: keystore.LABEL.format = PKCS12

=item keystore.LABEL.keyalg

Optional, the algorithm for key generation.

Default: the keytool default (provider dependent)

Example: keystore.LABEL.keyalg = RSA

=item keystore.LABEL.keysize

Optional, the bit size for key generation.

Default: the keytool default (provider dependent)

Example: keystore.LABEL.keysize = 2048

=item keystore.LABEL.sigalg

Optional, the signature algorithm used in the PKCS#10 request

Default: the keytool default (provider dependent)

Example: keystore.LABEL.sigalg = SHA1withRSA

=back

Limitations:

=over

=item

The key must be exportable (provider/keystore dependent, works for jks).

=item 

If the keystore contains multiple private keys, the renewal will work,
(provided that an alias has been configured) but the new keystore will 
contain only one private key (pertaining to the configured alias).

=item

Keytool expects the pin as a command line argument, hence it is visible 
in the process list for a short time.

=back

=head4 2.2.2.4 Windows keystore

Windows keystore description

=over

=item keystore.LABEL.location

Mandatory, specifies the Distinguished Name of a certificate in the Windows keystore, which shall be monitored/renewed. Only one certificate with the specified DN may be present in the store.

Example: 
    CN=www.example.com,O=Example Ltd.,DC=example,DC=com

=item keystore.LABEL.type

Mandatory, must literally be set to Windows.

=item keystore.LABEL.issuerregex

Issuer Distingushed Name as (Perl) regular expression.

=item keystore.LABEL.storename

Optional, specifies the name of the certificate store, e.g. MY. This setting should generally not be changed.

Default: MY

=item keystore.LABEL.storelocation

Optional, specifies the name of the certificate store location: memory, machine, user  

Default: machine

=back

Limitations:

=over

=item

The key must be exportable and strong private key protection may not be enabled.

=item 

If there are two or more identical certificates in the certificate store, the renewal process
will not work and one of the  certificates has to be removed manually.

=back

=head4 2.2.2.5 Windows IIS keystore

Windows IIS keystore description

=over

=item keystore.LABEL.location

Mandatory, specifies the Distinguished Name of a certificate in the Windows keystore, which shall be monitored/renewed. Only one certificate with the specified DN may be present in the store.

Example: 
    CN=www.example.com,O=Example Ltd.,DC=example,DC=com

=item keystore.LABEL.type

Mandatory, must literally be set to WindowsIIS.

=item keystore.LABEL.issuerregex

Issuer Distingushed Name as (Perl) regular expression.

=item keystore.LABEL.storename

Optional, specifies the name of the certificate store, e.g. MY. This setting should generally not be changed.

Default: MY

=item keystore.LABEL.storelocation

Optional, specifies the name of the certificate store location: memory, machine, user  

Default: machine

=item keystore.LABEL.instanceidentifier

Mandatory, specifies the Instance Name of the IIS server. The Instance Name is equal to the
identifier listed in 'Web Sites' in your IIS Manager. If you want to install the same certificate into
multiple instances, please provide a comma separated list.

Example:
    1,2,12440

Default: 1

=back

Limitations:

=over

=item

The key must be exportable and strong private key protection may not be enabled.

=item 

If there are two or more identical certificates in the certificate store, the renewal process
will not work and one of the  certificates has to be removed manually.

=back


=head4 2.2.2.6 PKCS#12 keystore

This keystore type is a raw PKCS#12 file that is e. g. used by Oracle.
The generated keystore will retain the existing FriendlyName as present
in the old keystore.

=over

=item keystore.LABEL.location

Mandatory, specifies the filename of the PKCS#12 file.

Example: 
    /path/to/my.p12

=item keystore.LABEL.type

Mandatory, must literally be set to PKCS12.

=item keystore.LABEL.pin

PKCS#12 PIN

=back


=head2 2.3 Advanced configuration features

=head3 2.3.1 Inheritance

All keystore instance can inherit from the definition of every other
already defined setting. By default, all keystore inherit from the
DEFAULT label.

=over 

=item keystore.LABEL.INHERIT

Default: keystore.LABEL.INHERIT = DEFAULT

Example: 
    keystore.myfirstkeystore.location = ...
    keystore.mysecondkeystore.INHERIT = myfirstkeystore

=back

=head3 2.3.2 Custom entries and referencing other configuration entries

The value of any setting can reference an already defined variable by
using the syntax $(key).

It is possible to add custom keys to the config file that are not
defined for the application (see section 2.1 and 2.2).

Example:
    foo.bar = World
    foo.baz = Hello $(foo.bar)


=head2 2.4 Sample configuration

See etc/certnanny.cfg


=head1 3 Running the program

CertNanny can be invoked in two different operation modes:

=over

=item

read-only mode "check":
    $ certnanny --cfg certnanny.cfg check

=item

renewal mode "renew"
    $ certnanny --cfg certnanny.cfg renew

=back

=head2 3.1 Checking certificates

In this mode the configured keystores are checked for expiration within
a configurable time period. A warning is printed to the terminal,
and it is possible to configure a hook that is executed for each
expiring certificate (e. g. for monitoring integration).


=head2 3.2 Automatic renewal

This is the main operation mode of CertNanny and causes the program
to iterate through all configured keystores. If a keystore is found
that matches the "renewal" criteria (i. e. expiry within the configured
time frame), an automatic renew is started.

The general procedure is described in Section 1.2.3.

After a renewal process has been started, the program keeps track of
the current status in the 'statedir' directory specified in the
configuration file.

All files belonging to a certain keystore contain the same base filename 
that is identical to the LABEL of the keystore as defined in the 
configuration file.

At any time it is possible to wipe the contents of the contents of the
'statedir' directory for a keystore. The enrollment will then start
from scratch. (NOTE: This may lead to problems on the CA side, because
the CA may have received a certificate request from the automatic
renewal process.)


=head1 Appendix

=head1 A Known bugs and deficiencies

=over

=item

Only RSA keys are supported

=item

New certificate chain inserted into the keystore is currently not
cryptographically verified

=back

=head1 B Ideas for enhancement

=head2 B.1 Automatic approval (already implemented)

=head2 B.2 Implicit load balancing on PKI and LDAP

Postpone each request scheduled by cron by a random amount of time
(e. g. 0 - 6 hours) to reduce load on the PKI and LDAP systems.


=head2 B.3 Automatic root certificate deployment

Use CertNanny to retrieve PKI root certificates e. g. via LDAP.
This process is optional, completely asynchronous and independent
from certificate renewal.

=over

=item

On each invocation poll LDAP directory for new root certificates

=item

If a new root cert is found, download it and store it in a
temporary directory. Record the timestamp of the first occurrance
of this certificate

=item

After a configurable amount of "quarantine" time (e. g. 10 days)
the process is repeated. If the same root certificate is still
persistent in the directory, the new root certificate is accepted as
valid and installed to the client system. Otherwise the rogue
certificate is discarded and an error is raised.

=back

This assumes that a fake root certificate in the LDAP directory is
noticed within a few hours or days by the PKI group and removed from
the directory. If a certificate has been in the directory for e. g.
10 days, the observing clients can be sure that it is a correct and
valid certificate.

A central monitoring script in the PKI should do the following:

=over

=item

On each invocation poll each LDAP directory server (all replicas
available in the network) for all root certificates.

=item

Verify every root certificate found against the own list of
trusted root certificates

=item

Raise a monitoring alarm if a rogue certificate was found

=back

PKI and LDAP operating staff are expected to remove the rogue
certificate within a period less than the minimum "quarantine" time
configured on the end entity systems.

=cut