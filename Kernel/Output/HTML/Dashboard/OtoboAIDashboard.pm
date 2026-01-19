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

package Kernel::Output::HTML::Dashboard::OtoboAIDashboard;

use strict;
use warnings;

use Kernel::System::VariableCheck qw(:all);
use Kernel::Language              qw(Translatable);

our $ObjectManagerDisabled = 1;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    # get needed parameters
    for my $Needed (qw(Config Name UserID)) {
        die "Got no $Needed!" if ( !$Self->{$Needed} );
    }

    return $Self;
}

sub Preferences {
    my ( $Self, %Param ) = @_;

    my @Params;

    return @Params;
}

sub Config {
    my ( $Self, %Param ) = @_;

    # check if frontend module of link is used
    if ( $Self->{Config}{Link} && $Self->{Config}{Link} =~ /Action=(.+?)([&;].+?|)$/ ) {
        my $Action = $1;
        if ( !$Kernel::OM->Get('Kernel::Config')->Get('Frontend::Module')->{$Action} ) {
            $Self->{Config}{Link} = '';
        }
    }

    return (
        %{ $Self->{Config} },

        # Don't cache this globally as it contains JS that is not inside of the HTML.
        CacheTTL => undef,
        CacheKey => undef,
    );
}

sub FilterContent {
    my ( $Self, %Param ) = @_;

    return;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    my $PollingInterval = $Kernel::OM->Get('Kernel::Config')->Get('OtoboAIDashboard::Frontend::PollingInterval') || 30;
    my $TimeoutInterval = $Kernel::OM->Get('Kernel::Config')->Get('OtoboAIDashboard::Frontend::TimeoutInterval') || 300;
    $LayoutObject->AddJSData(
        Key   => 'PollingInterval',
        Value => $PollingInterval,
    );
    $LayoutObject->AddJSData(
        Key   => 'TimeoutInterval',
        Value => $TimeoutInterval,
    );
    my $CacheObject     = $Kernel::OM->Get('Kernel::System::Cache');
    my $CacheKeyRequest = 'OtoboAI-Custom-Request-' . $Self->{UserID};
    my $RequestExists   = $CacheObject->Get(
        Type => 'OtoboAI',
        Key  => $CacheKeyRequest,
    );

    my $Content = $LayoutObject->Output(
        TemplateFile => 'OtoboAIDashboard',
        Data         => {
            Question => $RequestExists,
        }
    );

    return $Content;
}

1;
