#
# CertNanny - Automatic renewal for X509v3 certificates using SCEP
# 2005 - 2007 Martin Bartosch <m.bartosch@cynops.de>
#
# This software is distributed under the GNU General Public License - see the
# accompanying LICENSE file for more details.
#

package CertNanny::Keystore::SAP;

use base qw( Exporter CertNanny::Keystore::PKCS12 );

use strict;
use vars qw($VERSION);
use Exporter;
use Carp;
use English;
use MIME::Base64;
if($^O eq "MSWin32") {
    use File::Copy;
}


$VERSION = 0.10;

###########################################################################

# constructor
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
    
    my $entry = $self->{OPTIONS}->{ENTRY};
    my $entryname = $self->{OPTIONS}->{ENTRYNAME};
    
    # check that both directories exist
    my $out_dir;
    my $in_dir;
    
    $in_dir = $entry->{in_dir};
    if(! $in_dir or ! -d $in_dir) {
        CertNanny::Logging->error("keystore.$entryname.in_dir is either missing or not a directory, please check.");
        return;
    }
        
    $out_dir = $entry->{out_dir};
    if(! $out_dir or ! -d $out_dir) {
        CertNanny::Logging->error("keystore.$entryname.out_dir is either missing or not a directory, please check.");
        return;
    }
    
    my $filename = $entry->{filename};
    if(! $filename) {
        CertNanny::Logging->info("keystore.$entryname.filename is not specified, will look into $out_dir to find a file");
        opendir(DIR, $out_dir);
        my @files = grep ! /^\.{1,2}$/, readdir(DIR);
        closedir(DIR);
        if(@files > 1) {
            CertNanny::Logging->error("More than one file in $out_dir, cannot determine correct file. Please specify keystore.$entryname.filename.");
            return;
        }
        
        $filename = $files[0];
    }
    $self->{PKCS12}->{XMLFILENAME} = $filename;
    $self->{PKCS12}->{INDIR} = $in_dir;
    $self->{PKCS12}->{OUTDIR} = $out_dir;
    
    my $p12_xml_file;
    if( ! $filename or ! -r ($p12_xml_file = File::Spec->catfile($out_dir, $filename))) {
        CertNanny::Logging->info("No file present in $out_dir, no renewal required.");
        return;
    }
    
    
    opendir(DIR, $in_dir);
    my @files = grep ! /^\.{1,2}$/, readdir(DIR);
    closedir(DIR);
    if(@files) {
        CertNanny::Logging->info("There is still a file present from the last update. Will not continue");
        return;
    }
    
    my $p12_data_tag = $entry->{p12_data_tag};
    if(!$p12_data_tag) {
        CertNanny::Logging->info("keystore.$entryname.p12_data_tag no specified, will use defaul 'P12DATA'");
        $p12_data_tag = 'P12DATA';
    }
    
    my $p12_pwd_tag = $entry->{p12_pwd_tag};
    if(!$p12_pwd_tag) {
        CertNanny::Logging->info("keystore.$entryname.p12_pwd_tag no specified, will use defaul 'PWD'");
        $p12_pwd_tag = 'PWD';
    }
    
    my $p12_xml = CertNanny::Util->read_file($p12_xml_file);
    if(!$p12_xml) {
        CertNanny::Logging->error("XML file $p12_xml is empty.");
        return;
    }
    $self->{PKCS12}->{XML} = $p12_xml;
    #$p12_xml =~ m/.*?\<$p12_data_tag\>([A-Za-z0-9\+\/=]+)\<\/$p12_data_tag\>.*?\<$p12_pwd_tag\>(.*)?\<\/$p12_pwd_tag\>.*/s;
    $p12_xml =~ m/.*?<P12DATA>([\w\d\s+=\/]+?)<\/P12DATA>.*?<PWD>(.*?)<\/PWD>.*?/s;
    if(! $p12_xml ) {
        CertNanny::Logging->error("Could not parse XML file. Incorrect format");
        return;
    }
    
    my $p12_data = $1;
    my $p12_pwd = $2;
    $p12_data =~ s/\s//g;
    $p12_data = MIME::Base64::decode($p12_data);
    if(!$p12_data) {
        CertNanny::Logging->error("Could not retrieve PKCS#12 data.");
        return;
    }
    
    if(!$p12_pwd) {
        CertNanny::Logging->error("Could not get the PKCS#12 password, cannot parse data");
        return;
    }
    
    $self->{PKCS12}->{DATA} = $p12_data;
    $self->{PKCS12}->{PWD} = $p12_pwd;
       


    # the rest should remain untouched

    # get previous renewal status
    $self->retrieve_state() || return;

    # check if we can write to the file
    $self->store_state() || croak "Could not write state file $self->{STATE}->{FILE}";

    # instantiate keystore
    return $self;
}


# you may add additional destruction code here but be sure to retain
# the call to the parent destructor
sub DESTROY {
    my $self = shift;
    # check for an overridden destructor...
    $self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
}

# returns filename with all PKCS#12 data
sub get_pkcs12_file {
    my $self = shift;
    my $p12_file = CertNanny::Util->gettmpfile();
    my $p12_data = $self->{PKCS12}->{DATA};
    if(!CertNanny::Util->write_file((FILENAME => $p12_file, CONTENT => $p12_data, FORCE => 1))) {
        CertNanny::Logging->error("Could not write temporary PKCS#12 file");
        return;
    }
    return $p12_file;
}

sub get_pin {
    my $self = shift;
    return $self->{PKCS12}->{PWD};
}

# This method should generate a new private key and certificate request.
# You may want to inherit this class from CertNanny::Keystore::OpenSSL if
# you wish to generate the private key and PKCS#10 request 'outside' of
# your keystore and import this information later.
# In this case use the following code:
# sub createrequest
# {
#   return $self->SUPER::createrequest() 
#     if $self->can("SUPER::createrequest");
# }
#
# If you are able to directly operate on your keystore to generate keys
# and requests, you might choose to do all this yourself here:
sub createrequest {
    my $self = shift;
    return $self->SUPER::createrequest() 
	if $self->can("SUPER::createrequest");
    return;
}



# This method is called once the new certificate has been received from
# the SCEP server. Its responsibility is to create a new keystore containing
# the new key, certificate, CA certificate keychain and collection of Root
# certificates configured for CertNanny.
# A true return code indicates that the keystore was installed properly.
sub installcert {
    my $self = shift;
    my %args = ( 
		 @_,         # argument pair list
		 );

    my $data = MIME::Base64::encode($self->get_new_pkcs12_data(%args));
    return unless $data;
    
    my $p12_config = $self->{PKCS12};
    my $new_p12_xml = $p12_config->{XML};
    my $old_data = MIME::Base64::encode($p12_config->{DATA});
    $new_p12_xml =~ s/$old_data/$data/s;
    
    # create a temporary file which then will be moved over to the correct dir
    my $tmp_dir = $self->{OPTIONS}->{CONFIG}->get('path.tmpdir', 'FILE');
    my $xml_filename = $p12_config->{XMLFILENAME};
    my $new_p12_xml_file = File::Spec->catfile($tmp_dir, $xml_filename);
    if(!CertNanny::Util->write_file((FILENAME => $new_p12_xml_file, CONTENT => $new_p12_xml, FORCE => 1))) {
        CertNanny::Logging->error("Could not create temporary file to store PKCS12 XML file");
        return;
    }
    
    # temporary file written, before moving it to in_dir, remove old file from
    my $out_dir = $p12_config->{OUTDIR}; 
    my $old_xml_file = File::Spec->catfile($out_dir, $xml_filename);
    my $in_dir = $p12_config->{INDIR};
    my $new_xml_file = File::Spec->catfile($in_dir, $xml_filename);
    if(! unlink $old_xml_file) {
        CertNanny::Logging->error("Could not delete old XML file. Will continue to prevent loss of renewed certificate.");
    }
    # temporary file written, move it to the in_dir
    if($^O eq "MSWin32") {
        if(!move($new_p12_xml_file, $new_xml_file)) {
            my $output = $!;
            CertNanny::Logging->error("Could not move temporary file to in_dir: $output");
            return;
        }
    } else {
        my $output = `mv $new_p12_xml_file $new_xml_file`;
        if($?) {
            chomp($output);
            CertNanny::Logging->error("Could not move temporary file to in_dir: $output");
            return;
        }
    }
    
    # only on success:
    return 1;
}

1;