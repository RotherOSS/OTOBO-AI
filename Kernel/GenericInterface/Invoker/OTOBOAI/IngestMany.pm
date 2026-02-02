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

package Kernel::GenericInterface::Invoker::OTOBOAI::IngestMany;

use v5.24;
use strict;
use warnings;

# core modules
use MIME::Base64 qw(encode_base64);

# CPAN modules
use URI::Escape qw(uri_unescape);

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);

our $ObjectManagerDisabled = 1;

=head1 NAME

Kernel::GenericInterface::Invoker::OTOBOAI::IngestMany

=head1 PUBLIC INTERFACE

=head2 new()

usually, you want to create an instance of this
by using Kernel::GenericInterface::Invoker->new();

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = bless {}, $Type;

    # check needed params and store them in $Self
    for my $Needed (qw/DebuggerObject WebserviceID/) {
        if ( !$Param{$Needed} ) {
            return {
                Success      => 0,
                ErrorMessage => "Need $Needed!"
            };
        }

        $Self->{$Needed} = $Param{$Needed};
    }

    return $Self;
}

=head2 PrepareRequest()

prepare the invocation of the configured remote web service. This will ingest data
into the Otobo AI vector DB.

    my $Result = $InvokerObject->PrepareRequest(
        Data => {                               # data payload
            Content => $Content,                # data payload
            Type    => 'faq',                   # one of faq|ticket_pairs|ticket_chunks|doc
        },
    );

    $Result = {
        Success         => 1,                   # 0 or 1
        ErrorMessage    => '',                  # in case of error
        Data    => {
            type    => $Param{Data}{Type},
            content => $Param{Data}{Content},
            $TypeSettings{ $Param{Data}{Type} }->%*,
        },
    };

=cut

sub PrepareRequest {
    my ( $Self, %Param ) = @_;

    # check needed I
    for my $Needed (qw/Content Type/) {
        if ( !$Param{Data}{$Needed} ) {
            return {
                Success      => 0,
                ErrorMessage => "Need $Needed!",
            };
        }
    }

    my $JSONObject = $Kernel::OM->Get('Kernel::System::JSON');

    my %TypeSettings = (
        faqs => {
            embed_content_types => ['question'],
            store_fulltext      => $JSONObject->True(),
            fulltext_types      => ['answer'],
        },
        docs => {
            embed_content_types => ['text'],
            store_fulltext      => $JSONObject->False(),
            fulltext_types      => ['text'],
        },
        ticket_pairs => {
            embed_content_types => ['question'],
            store_fulltext      => $JSONObject->True(),
            fulltext_types      => ['answer'],
        },
        ticket_chunks => {
            embed_content_types => ['text'],
            store_fulltext      => $JSONObject->False(),
            fulltext_types      => ['text'],
        },
    );

    if ( !$TypeSettings{ $Param{Data}{Type} } ) {
        return {
            Success      => 0,
            ErrorMessage => "Type $Param{Data}{Type} not supported.",
        };
    }

    return {
        Success => 1,
        Data    => {
            type    => $Param{Data}{Type},
            content => $Param{Data}{Content},
            $TypeSettings{ $Param{Data}{Type} }->%*,
        },
    };
}

=head2 HandleResponse()

handle response data of the configured remote web service.
This will just return the data that was passed to the function.

    my $Result = $InvokerObject->HandleResponse(
        ResponseSuccess      => 1,              # success status of the remote web service
        ResponseErrorMessage => '',             # in case of web service error
        Data => {                               # data payload
            ...
        },
    );

    $Result = {
        Success         => 1,                   # 0 or 1
        ErrorMessage    => '',                  # in case of error
        Data            => {                    # data payload after Invoker
            ...
        },
    };

=cut

sub HandleResponse {
    my ( $Self, %Param ) = @_;

    # if there was an error in the response, forward it
    if ( !$Param{ResponseSuccess} ) {
        return {
            Success      => 0,
            ErrorMessage => $Param{ResponseErrorMessage},
        };
    }

    # extra handling for errors from python ai container
    if(IsHashRefWithData($Param{Data}) && exists($Param{Data}{success})) {
        if($Param{Data}{success} == 0 ) {

            return {
                Success      => 0,
                ErrorMessage => $Param{ResponseErrorMessage},
            };
        }
    }

    return {
        Success => 1,
        Data    => $Param{Data},
    };
}

1;
