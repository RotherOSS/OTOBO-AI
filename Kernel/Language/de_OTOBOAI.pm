# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

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
