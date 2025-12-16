package Kernel::Language::de_OTOBOAI;

use strict;
use warnings;
use utf8;

sub Data {
    my $Self = shift;

    # SysConfig Dropdown Value
    $Self->{Translation}->{'Synchronous'} = 'Synchron';
    $Self->{Translation}->{'Your request was canceled'} = 'Die Anfrage wurde abgebrochen';
    $Self->{Translation}->{'Your request has failed'} = 'Die Anfrage ist fehlgeschlagen';
    $Self->{Translation}->{'Your request has timed out'} = 'Ihre Anfrage ist abgelaufen';
    $Self->{Translation}->{'Send request'} = 'Anfrage übermitteln';

    push @{ $Self->{JavaScriptStrings} // [] }, (
        'Your request was canceled',
        'Your request has failed',
        'Your request has timed out',
        'Send request',
    );
}


1;
