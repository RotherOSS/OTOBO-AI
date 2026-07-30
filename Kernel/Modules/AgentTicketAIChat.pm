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

use Net::DNS;
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
    my $LayoutObject      = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    # fetch data
    my $MCPHost   = $ConfigObject->Get('OTOBOAI::MCP::Host');
    my $ChatURL   = $ConfigObject->Get('OTOBOAI::Chat::Endpoint');
    my $CheckIP   = $ConfigObject->Get('SessionCheckRemoteIP');
    my $TicketID  = $ParamObject->GetParam( Param => 'TicketID' );
    my $ArticleID = $ParamObject->GetParam( Param => 'ArticleID' );
    my %UserData  = $UserObject->GetUserData( UserID => $Self->{UserID} );
    my $FQDN      = $ConfigObject->Get('FQDN');

    # determine remote IP of mcp server to bind session to
    my $RemoteIP = 'none';

    if ($CheckIP) {

        $RemoteIP = $Self->GetMCPRemoteAddr( MCP => $MCPHost );
        if ( !$RemoteIP ) {
            return $LayoutObject->FatalError( Message => "Cannot resolve IP address of MCP. Unable to create a chat session." );
        }
    }

    # create mcp bound webservice session
    my $SessionID = $AuthSessionObject->CreateSessionID(
        %UserData,
        UserLastRequest => $Kernel::OM->Create('Kernel::System::DateTime')->ToEpoch(),
        UserType        => 'User',
        SessionSource   => 'GenericInterface',
        RemoteAddr      => $RemoteIP,
    );
    if ( !$SessionID ) {
        return $LayoutObject->FatalError( Message => "Cannot create new chat session." );
    }

    # assemble redirect URL
    $SessionID = uri_escape_utf8($SessionID);
    $ChatURL =~ s/\{\{FQDN\}\}/https:\/\/$FQDN/;
    $ChatURL =~ s/\{\{OTOBO_SID\}\}/otobo_sid\%3D$SessionID/;

    if ($TicketID) {
        $ChatURL =~ s/\{\{TICKET_ID\}\}/+ticket_id\%3D$TicketID/;
    }
    else {
        $ChatURL =~ s/\{\{TICKET_ID\}\}//;
    }

    if ($ArticleID) {
        $ChatURL =~ s/\{\{ARTICLE_ID\}\}/+article_id\%3D$ArticleID/;
    }
    else {
        $ChatURL =~ s/\{\{ARTICLE_ID\}\}//;
    }

    # redirect to chat
    $LayoutObject->Redirect(
        ExtURL => $ChatURL,
    );

    return;
}

sub GetMCPRemoteAddr {

    my ( $Self, %Param ) = @_;

    my $MCP = $Param{'MCP'} || 'mcp';

    my $Resolver = Net::DNS::Resolver->new;
    $Resolver->tcp_timeout(10);
    $Resolver->udp_timeout(10);

    my $Result = $Resolver->search($MCP);
    return if !$Result;

    RECORD:
    for my $Record ( $Result->answer ) {

        if ( $Record->can('address') ) {

            return $Record->address;
        }
    }

    return;
}

1;
