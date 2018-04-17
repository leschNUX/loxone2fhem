#############################################
# $Id: 93_LOXONE.pm 0000 2000-11-03 00:00:50Z bentele $
# Autor: Gabriel Bentele - gabriel at bentele de
# 
# Changes
# 19.01.2017 - initial 
# 03.03.2017 - add helper functions to send data via udp to Miniserver
# 07.11.2017 - add motion function for ZWAVE
# 17.04.2018 - update
###############################################

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use HttpUtils;
use IO::Socket;

sub LOXONE_Read($);
sub LOXONE_Ready($);
sub LOXONE_OpenDev($$);
sub LOXONE_CloseDev($);
sub LOXONE_Disconnected($);
sub LOXONE_Define($$);
sub LOXONE_Undef($$);

sub
LOXONE_Initialize($)
{
  my ($hash) = @_;

# Provider
  $hash->{ReadFn}  = "LOXONE_Read";
  $hash->{WriteFn} = "LOXONE_Write";
  $hash->{ReadyFn} = "LOXONE_Ready";
  $hash->{SetFn}   = "LOXONE_Set";
  $hash->{noRawInform} = 1;

# Normal devices
  $hash->{DefFn}   = "LOXONE_Define";
  $hash->{UndefFn} = "LOXONE_Undef";
  $hash->{AttrList}= "dummy:1,0 disable:0,1 disabledForIntervals";
}

#####################################
sub
LOXONE_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $dev = "127.0.0.1";
  $hash->{Host} = $dev;
  $hash->{PORT} = $a[2];
  $hash->{Loxone} = $a[3];

  LOXONE_CloseDev($hash);
  return LOXONE_OpenDev($hash, 0);
}

#####################################
sub
LOXONE_Undef($$)
{
  my ($hash, $arg) = @_;
  LOXONE_CloseDev($hash); 
  return undef;
}

sub
LOXONE_Write($$)
{
  my ($hash,$fn,$msg) = @_;
  my $dev = $hash->{Host};

}

#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub
LOXONE_Read($)
{
  my ($hash) = @_;

  my $buf = LOXONE_SimpleRead($hash);
  my $name = $hash->{NAME};

  ###########
  # Lets' try again: Some drivers return len(0) on the first read...
  if(defined($buf) && length($buf) == 0) {
    $buf = LOXONE_SimpleRead($hash);
  }

  if(!defined($buf) || length($buf) == 0) {
    LOXONE_Disconnected($hash);
    return;
  }

  return if(IsDisabled($name));

  my $data = $hash->{PARTIAL};
  Log3 $hash, 5, "LOXONE/RAW: $data/$buf";
  $data .= $buf;

  while($data =~ m/\n/) {
    my $rmsg;
    ($rmsg,$data) = split("\n", $data, 2);
    $rmsg =~ s/\r//;
    #$rmsg =~ s///;
    Log3 $name, 4, "$name full message: $rmsg";
    my ($tmp,$bez,$value) = split ("\;", $rmsg);
    Log3 $name, 5, "devicename: $bez value: $value ";
	
    readingsSingleUpdate($hash, $bez, $value ,1);

    # gibt es ein internes device?
    if ( defined ($defs{$bez})){
      if ( defined ($defs{$bez}->{STATE} )){
        my $mystatus=$defs{$bez}->{STATE};
        Log3 $name, 3, "LOXONE device: $bez new: $value current:  $mystatus ";
		# ist es ein Schalter?
        if ( $mystatus eq "on" && $value eq "0"){
	    fhem("set $bez off");
            Log3 $name, 4, "LOXONE devicename: $bez value before: $value after: off";
        }
        elsif ( $mystatus eq "off" && $value eq "1"){
	    fhem("set $bez on");
            Log3 $name, 4, "LOXONE devicename: $bez value before: $value after: on ";
        }
      }
   }

  }
  $hash->{PARTIAL} = $data;
}


#####################################
sub
LOXONE_Ready($)
{
  my ($hash) = @_;
  return LOXONE_OpenDev($hash, 1);
}

########################
sub
LOXONE_CloseDev($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $dev = $hash->{Host};

  return if(!$dev);
  
  $hash->{UDPDev}->close() if($hash->{UDPDev});
  #$hash->{TCPDev2}->close() if($hash->{TCPDev2});
  delete($hash->{NEXT_OPEN});
  #delete($hash->{TCPDev});
  #delete($hash->{TCPDev2});
  delete($selectlist{"$name.$dev"});
  delete($readyfnlist{"$name.$dev"});
  delete($hash->{FD});
}

########################
sub
LOXONE_OpenDev($$)  
{
  my ($hash, $reopen) = @_;
  my $dev = $hash->{Host}; # immer udp localhost
  my $name = $hash->{NAME}; 
  my $port = $hash->{PORT};

  $hash->{PARTIAL} = "";
  Log3 $name, 3, "LOXONE opening $name at $dev port: $port" 
        if(!$reopen);

  return if($hash->{NEXT_OPEN} && time() <= $hash->{NEXT_OPEN});
  return if(IsDisabled($name));

  my $sock2fhem = IO::Socket::INET ->new(LocalPort => $port, Proto => 'udp');

  if (!$sock2fhem){
    Log3 $name, 3, "LOXONE $name port: $port ERROR open udp socket: $@" ;
  }

  if (defined($sock2fhem)){ 
    $hash->{UDPDev} = $sock2fhem;
    $hash->{FD} = $sock2fhem->fileno();
    delete($readyfnlist{"$name.$dev"});
    $selectlist{"$name.$dev"} = $hash;
    
    $hash->{STATE}= "connected";
    DoTrigger($name, "CONNECTED") if($reopen);
     delete($hash->{NEXT_OPEN});
    return;
  }else{
      #$readyfnlist{"$name.$dev"} = $hash;
      $hash->{STATE} = "disconnected";
      $hash->{NEXT_OPEN} = time()+60;
      return;
  }
}

sub
LOXONE_Disconnected($)
{
  my $hash = shift;
  my $dev = $hash->{Host};
  my $name = $hash->{NAME};

  return if(!defined($hash->{FD}));                 # Already deleted
  Log3 $name, 1, "$dev disconnected, waiting to reappear";
  LOXONE_CloseDev($hash);
  $readyfnlist{"$name.$dev"} = $hash;               # Start polling
  $hash->{STATE} = "disconnected";

  return if(IsDisabled($name)); #Forum #39386

  # Without the following sleep the open of the device causes a SIGSEGV,
  # and following opens block infinitely. Only a reboot helps.
  sleep(5);

  DoTrigger($name, "DISCONNECTED");
}

########################
sub
LOXONE_SimpleRead($)
{
  my ($hash) = @_;
  my $buf;
  if(!defined(sysread($hash->{UDPDev}, $buf, 256))) {
    LOXONE_Disconnected($hash);
    return undef;
  }
  return $buf;
}

sub
LOXONE_Set($@)
{
  my ($hash, @a) = @_;

  return "set needs at least one parameter" if(@a < 2);
  return "Unknown argument $a[1], choose one of reopen:noArg"
  	if($a[1] ne "reopen");

  LOXONE_CloseDev($hash);
  LOXONE_OpenDev($hash, 0);
  return undef;
}

sub LOXONE_UDP($$)
{
	my ($miniserver, $cmd) = @_;
	Log 5, "LOXONE UDP miniserver: $miniserver message: $cmd";
	if ( defined($defs{$miniserver})){
		my $hash=$defs{$miniserver};
		my $dest = $hash->{Loxone};
		my $port = $hash->{PORT};
		my $sock = IO::Socket::INET->new(
		  Proto => 'udp',
		  PeerPort => $port,
		  PeerAddr => $dest
		) or die "Could not create socket: $!n";
		$sock->send($cmd) or die "Send error: $!n";
		Log 4, "LOXONE UDP Loxone Miniserver: $dest port: $port commando: $cmd";
		#return "send $cmd";
	}else{
		Log 3, "LOXONE UDP device $miniserver not defined";
	}
		return undef
}


#EnergyToLoxone
sub 
LOXONE_Energy($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
 #$reading =~ s/://;
 if ( $reading ne "energyTotal:" ){
     $value=$value/1000;
 }
 Log 4, "LOXONE Energy: miniserver: $miniserver device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $value");
 return undef;
}

#MotionToLoxone
sub LOXONE_Motion($$$)
{
 my ($miniserver, $device, $value) = @_;
 my $reading= "basicSet";
 my $state = "";
 if ($value eq "255") {
	$state = "1";
 }
 if ($value eq "0") {
	$state = "0";
 }
 Log 4, "LOXONE Motion device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading: $state");
 return undef;
}

# Loxone RGB in HEX-RGB umrechnen
sub percent2rgb($)           
{                            
  my($percent) = @_;         
                               
  # my($r,$g,$b) = ($percent =~ m/(\d\d\d)(\d\d\d)(\d\d\d)/);
  my $r = substr $percent, -3;
  my $g = substr $percent, -6, 3;
  my $b = substr $percent, -9, 3;
  
  return sprintf( "%02X%02X%02X", $r*2.55+0.5, $g*2.55+0.5, $b*2.55+0.5 );
}



sub LOXONE_Kwl($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
 my $level = "";
 if ( $value eq "auto" )    { $level ="1"};
 if ( $value eq "abwesend" ){ $level ="2"};
 if ( $value eq "niedrig" ) { $level ="3"};
 if ( $value eq "mittel" )  { $level ="4"};
 if ( $value eq "hoch" )    { $level ="5"};
 Log 4, "LOXONE Kwl device: $device reading: $reading value: $value level $level";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $level");
 return undef;
}

#ClimateToLoxone
sub LOXONE_Climate($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
 Log 4, "LOXONE Climate device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $value");
 return undef;
}

#GENERICToLoxone
sub LOXONE_Generic($$$)
{
 my $reading= "state";
 my ($miniserver, $device, $value) = @_;
 Log 4, "LOXONE Generic device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading: $value");
 return undef;
}

#GENERICToLoxone
sub LOXONE_Generic4($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
 Log 4, "LOXONE Generic device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $value");
 return undef;
}


#AIRCONDToLoxone
sub LOXONE_Aircond($$$)
{
 my $reading= "state";
 my ($miniserver, $device, $value) = @_;
 Log 4, "LOXONE Climate device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $value");
 return undef;
}

#Wetter
sub LOXONE_Wetter($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
 Log 4, "LOXONE Wetter device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $value");
 return undef;
}

#OnOffToLoxone
#device:
#1 state(0,1)
#2 pct(0-100)
sub LOXONE_OnOff($$$)
{
 my ($miniserver, $device, $value) = @_;
 my $reading= "state";
 my $state = "";
 if ($value eq "on") {
	$state = "1";
 }
 if ($value eq "off") {
	$state = "0";
 }
 Log 4, "LOXONE OnOff device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading: $state");
 return undef;
}

sub LOXONE_Sonoff_OnOff($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
    my $state = "";
 if ($value eq "ON") {
	$state = "1";
 }
 if ($value eq "OFF") {
	$state = "0";
 }
 Log 4, "LOXONE OnOff device: $device reading: $reading value: $value";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $state");
 return undef;
}

#OpenClosedToLoxone
#device
#1 state(0,1)
#2 alive(1-0)
#3 battery(0,1)
sub LOXONE_OpenClosed($$$)
{
 my ($miniserver, $device, $value) = @_;
 #my $state = ReadingsVal("$device","state","-1");
 #Log 3, "LOXONE_OpenClosed state: $state device: $device";
 my $reading="state";
 my $state="";
 if ($value eq "closed" || $value eq "Closed") {
	$state = "0";
 }
 if ($value eq "open" || $value eq "Open") {
	$state = "1";
 }
 # Log 5, "LOXONE OpenClosed device: $device state: $state alive: $alive battery: $battery sabotage: $sabotage";
 # Log 3, "LOXONE_Heizung miniserver: $miniserver device: $device reading: $reading value: $value";
 Log 4, "LOXONE OpenClosed miniserver: $miniserver device: $device state: $state";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading: $state");
 return undef;
}

sub LOXONE_1WReedContact($$$$)
{
 my ($miniserver, $device, $reading, $value) = @_;
 my $state="";
 if ($value eq "closed" || $value eq "Closed") {
	$state = "0";
 }
 if ($value eq "open" || $value eq "Open") {
	$state = "1";
 }
 # Log 5, "LOXONE OpenClosed device: $device state: $state alive: $alive battery: $battery sabotage: $sabotage";
 # Log 3, "LOXONE_Heizung miniserver: $miniserver device: $device reading: $reading value: $value";
 Log 4, "LOXONE 1WReedContact miniserver: $miniserver device: $device reading: $reading state: $state";
 $device.="_";
 LOXONE_UDP($miniserver, "$device$reading $state");
 return undef;
}


sub LOXONE_Heizung($$$$)
{
 my ($event) = @_;
 my ($miniserver, $device, $reading, $value) = @_;
 $reading =~ s/://;
# Log 4, "HeizungToLoxone event: $event";
# my $temperature = "";
# if ( $event eq "flowTemperature" ){
#     $temperature=ReadingsVal("heizung","$event","-1");
# }
# if ( $event eq "ambientTemperature" ){
#     $temperature=ReadingsVal("heizung","$event","-1");
# }
# if ( $event eq "returnTemperature" ){
#     $temperature=ReadingsVal("heizung","$event","-1");
# }
# if ( $event eq "hotWaterTemperature" ){
#     $temperature=ReadingsVal("heizung","$event","-1");
# }
# if ( $event eq "ambientTemperature" ){
#     $temperature=ReadingsVal("heizung","$event","-1");
# }
#     $event .= $event . ": ";
  Log 4, "LOXONE_Heizung miniserver: $miniserver device: $device reading: $reading value: $value";
 $device.="_";
  LOXONE_UDP($miniserver , "$device$reading: $value");
 return undef;
}

#DenonToLoxone
#1 power
#2 input
#3 volume
#4 mute
sub DenonToLoxone($$$)
{
 my ($miniserver, $device, $value) = @_;
 
 my $power=ReadingsVal("$device","power","-1");
 if ($power eq "on") {
  $power = "1";
 }
 if ($power eq "off") {
  $power = "0";
 }
 my $input=ReadingsVal("$device","input","-1");
 if ($input eq "bd") {
  $input = "1";
 }
 if ($input eq "btAudio") {
  $input = "2";
 }
 if ($input eq "cd") {
  $input = "3";
 }
 if ($input eq "cdrTape") {
  $input = "4";
 }
 if ($input eq "DVD") {
  $input = "5";
 }
 if ($input eq "dvrBdr") {
  $input = "6";
 }
 if ($input eq "favorites") {
  $input = "7";
 }
 if ($input eq "hdmi1") {
  $input = "8";
 }
 if ($input eq "hdmi2") {
  $input = "9";
 }
 if ($input eq "hdmi3") {
  $input = "10";
 }
 if ($input eq "hdmi4") {
  $input = "11";
 }
 if ($input eq "hdmi5Mhl") {
  $input = "12";
 }
 if ($input eq "hdmi6") {
  $input = "13";
 }
 if ($input eq "hdmi7") {
  $input = "14";
 }
 if ($input eq "hdmi8") {
  $input = "15";
 }
 if ($input eq "hdmiCyclic") {
  $input = "16";
 }
 if ($input eq "homeMediaGallery") {
  $input = "17";
 }
 if ($input eq "internetRadio") {
  $input = "18";
 }
 if ($input eq "ipodUsb") {
  $input = "19";
 }
 if ($input eq "mediaServer") {
  $input = "20";
 }
 if ($input eq "mhl") {
  $input = "21";
 }
 if ($input eq "multiChIn") {
  $input = "22";
 }
 if ($input eq "pandora") {
  $input = "23";
 }
 if ($input eq "phono") {
  $input = "24";
 }
 if ($input eq "satCbl") {
  $input = "25";
 }
 if ($input eq "sirius") {
  $input = "26";
 }
 if ($input eq "spotify") {
  $input = "27";
 }
 if ($input eq "tuner") {
  $input = "28";
 }
 if ($input eq "TV") {
  $input = "29";
 }
 if ($input eq "usbDac") {
  $input = "30";
 }
 if ($input eq "video1") {
  $input = "31";
 }
 if ($input eq "video2") {
  $input = "32";
 }
 if ($input eq "xmRadio") {
  $input = "33";
 }
 my $volume=ReadingsVal("$device","volume","-1");
 my $mute=ReadingsVal("$device","mute","-1");
 if ($mute eq "on") {
  $mute = "1";
 }
 if ($mute eq "off") {
  $mute = "0";
 }
 
 Log 4, "LOXONE_DENON_AVR to miniserver: $miniserver device: $device power: $power input: $input volume: $volume mute: $mute";
 #$device.="_";
  LOXONE_UDP($miniserver , "$device: $power $input $volume $mute");
 return undef;
}


sub WgetToLoxone($$$)
{
	my ($device, $reading, $value) = @_;
	my $ret = "";
	my $readingweekday = "";
	my $reading = (split(":",$reading))[0];
	if ($reading eq "myAbfallNowDatumToLoxone"){
		$readingweekday=ReadingsVal("$device","myAbfallNowWochentagToLoxone","-1");
		$readingweekday .= "%20";
		$readingweekday .= $value;
		$value = $readingweekday;
		}
	if ($reading eq "myAbfallNextDatumToLoxone"){
		$readingweekday=ReadingsVal("$device","myAbfallNextWochentagToLoxone","-1");
		$readingweekday .= "%20";
		$readingweekday .= $value;
		$value = $readingweekday;
	}
	
	$ret .=  system("wget -q -O /dev/null 'http://vitali:130784\@loxone.fritz.box/dev/sps/io/$reading/$value'");
	$ret =~ s,[r]*,,g;
	Log 4, "LOXONE_AbfallKalender: device: $device reading: $reading value: $value";
}

sub WgetToLoxoneTraffic($$$)
{
	my ($device, $reading, $value) = @_;
	my $ret = "";
	my $readingtrafficdelay = "";
	my $readingtrafficreturn = "";
	my $reading = (split(":",$reading))[0];
	if ($reading eq "delay_min"){
		$readingtrafficdelay=ReadingsVal("$device","duration_in_trafficToLoxone","-1");
		$readingtrafficdelay .= "%20delay%20";
		$readingtrafficdelay .= ReadingsVal("$device","delay_min","-1");
		$value = $readingtrafficdelay;
		}
	if ($reading eq "return_delay_min"){
		$readingtrafficreturn=ReadingsVal("$device","return_duration_in_trafficToLoxone","-1");
		$readingtrafficreturn .= "%20delay%20";
		$readingtrafficreturn .= ReadingsVal("$device","return_delay_min","-1");
		$value = $readingtrafficreturn;
		}
	
	$ret .=  system("wget -q -O /dev/null 'http://vitali:130784\@loxone.fritz.box/dev/sps/io/$reading/$value'");
	$ret =~ s,[r]*,,g;
	Log 4, "LOXONE_MapsTraffic: device: $device reading: $reading value: $value";
}



1;

=pod
=item helper
=item summary    open UDP Port and waiting for incomming Loxone Data
=item summary_DE Öffnet eine UDP Verbindung um daten von Loxone zu empfangen
=begin html

<a name="LOXONE"></a>
<h3>LOXONE</h3>
<ul>
  LOXONE is a helper module to open an UDP Port.
  <br><br>
  <a name="LOXONEdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; LOXONE &lt;Port&gt; &lt;Miniserver&gt; 
    </code>
  <br>
  <br>

  Examples:
  <ul>
    <code>define miniserver LOXONE 2000 192.168.178.10</code><br>
  </ul>
  <br>

  <a name="LOXONEset"></a>
  <b>Set </b>
  <ul>
    <li>reopen<br>
	Reopens the connection to the device and reinitializes it.</li><br>
  </ul>

  <a name="LOXONEget"></a>
  <b>Get</b> <ul>N/A</ul><br>

  <a name="LOXONEattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#dummy">dummy</a></li>
    <li><a href="#disable">disable</a></li>
    <li><a href="#disabledForIntervals">disabledForIntervals</a></li>
  </ul>

</ul>

=end html

=begin html_DE

<a name="LOXONE"></a>
<h3>LOXONE</h3>
<ul>
   LOXONE ist ein Hilfsmodul, um einen UDP zu öffnen.
   <br><br>
   <a name="LOXONEdefine"></a>
   <b>Define</b>
   <ul>
    <code>define &lt;name&gt; LOXONE &lt;Port&gt; &lt;Miniserver&gt; 
    </code>
   <br>
 
   <br>
   Beispiele:
   <ul>
     <code>define miniserver LOXONE 2000 192.168.178.10</code><br>
   <br>

   <a name="LOXONEset"></a>
   <b>Set </b>
   <ul>
     <li>reopen<br>
 	&Ouml;ffnet die Verbindung erneut.</li>
   </ul>

   <a name="LOXONEget"></a>
   <b>Get</b> <ul>N/A</ul><br>

   <a name="LOXONEattr"></a>
   <b>Attribute</b>
   <ul>
     <li><a href="#dummy">dummy</a></li>
      <li><a href="#disable">disable</a></li>
      <li><a href="#disabledForIntervals">disabledForIntervals</a></li>
   </ul>

</ul>

=end html_DE

=cut
