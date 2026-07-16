# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
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

package Kernel::Modules::AgentTicketAIChat;

use strict;
use warnings;

use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);

our $ObjectManagerDisabled = 1;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $ConfigObject      = $Kernel::OM->Get('Kernel::Config');
    my $AuthSessionObject = $Kernel::OM->Get('Kernel::System::AuthSession');
    my $UserObject        = $Kernel::OM->Get('Kernel::System::User');
    my $ParamObject       = $Kernel::OM->Get('Kernel::System::Web::Request');

    my $MCPEndpoint = $ConfigObject->Get('OTOBOAI::MCP::Endpoint');
    my $TicketID    = $ParamObject->GetParam( Param => 'TicketID' );

    my %UserData = $UserObject->GetUserData( UserID => $Self->{UserID} );

    my $RemoteIP = $Self->GetMCPRemoteAddr( MCPEndpoint => $MCPEndpoint );

    my $SessionID = $AuthSessionObject->CreateSessionID(
        %UserData,
        UserLastRequest => $Kernel::OM->Create('Kernel::System::DateTime')->ToEpoch(),
        UserType        => 'User',
        SessionSource   => 'GenericInterface',
        RemoteAddr      => $RemoteIP,
    );

    if ( !$SessionID ) {
        return "ERROR getting SID";
    }

    $SessionID = uri_escape_utf8($SessionID);

    my $ChatURL = $ConfigObject->Get('OTOBOAI::Chat::Endpoint');

    $ChatURL =~ s/\{\{OTOBO_SID\}\}/$SessionID/;
    $ChatURL =~ s/\{\{TICKET_ID\}\}/$TicketID/;

    return "<script>window.location='$ChatURL';</script>";
}

sub GetMCPRemoteAddr {

    my ( $Self, %Param ) = @_;

    # TODO: SysConf
    my $MCPEndpoint = $Param{MCPEndpoint};

    my $UA = LWP::UserAgent->new;
    $UA->agent("Otobo/11");

    my $Req = HTTP::Request->new(
        GET => $MCPEndpoint,
        [ 'Accept' => 'text/event-stream' ]
    );
    my $Res = $UA->request($Req);

    my $RemoteIP = $Res->header('client-peer');
    $RemoteIP =~ s/:[^:]*$//;

    return $RemoteIP;
}

1;
