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

package Kernel::GenericInterface::Invoker::OTOBOAI::QueryEmbeddings;

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

=for stopwords ai

=head1 NAME

Kernel::GenericInterface::Invoker::OTOBOAI::QueryEmbeddings

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

Prepare the invocation of the configured remote web service. This will query the
otobo-ai-docker container for a RAG answer.

    my $Result = $InvokerObject->PrepareRequest(
        Data => {                               # data payload
            Collection  => 'faqs',
            Labels      => [],
            Fulltext    => 0|1,
            Limit       => 3, # default
            Query       => 'searchterm',
        },
    );

    $Result = {
        Success         => 1,                   # 0 or 1
        ErrorMessage    => '',                  # in case of error
        Data    => {
            "type" : "faqs",
            "labels" : [ "default" ],
            "retrieve_fulltext" : "1",
            "n_results" : 3,
            "query_text" : "Katze"
        },
    };

=cut

sub PrepareRequest {
    my ( $Self, %Param ) = @_;

    my $Collection = $Param{Data}{Collection};
    my $Labels     = $Param{Data}{Labels};
    my $Fulltext   = $Param{Data}{Fulltext} // 0;
    my $Limit      = $Param{Data}{Limit}    // 3;
    my $Query      = $Param{Data}{Query};

    # check needed
    for my $Needed (qw/Collection Labels Query/) {
        if ( !$Param{Data}{$Needed} ) {
            return {
                Success      => 0,
                ErrorMessage => "Need $Needed!",
            };
        }
    }

    return {
        Success => 1,
        Data    => {
            type              => $Collection,
            labels            => $Labels,
            retrieve_fulltext => $Fulltext,
            n_results         => $Limit,
            query_text        => $Query,
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
        Data            => [
            {
                'id' => '13f89461-cb36-489e-b294-e85d8dc67ca2',
                'metadata' => {
                    'fulltext' => 'answer: <solution part of FAQ>!',
                    'label' => 'default',
                    'source_id' => '1'
                },
                'page_content' => '<Title,Question and Problem part of the FAQ>',
                'type' => 'Document'
            },
        ],
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

    return {
        Success => 1,
        Data    => $Param{Data},
    };
}

1;
