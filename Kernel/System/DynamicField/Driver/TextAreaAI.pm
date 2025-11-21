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

package Kernel::System::DynamicField::Driver::TextAreaAI;

## nofilter(TidyAll::Plugin::OTOBO::Perl::ParamObject)

use v5.24;
use strict;
use warnings;
use namespace::autoclean;
use utf8;

use parent qw(Kernel::System::DynamicField::Driver::TextArea);

# core modules

# CPAN modules

# OTOBO modules
use Kernel::Language              qw(Translatable);
use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = ();

=head1 NAME

Kernel::System::DynamicField::Driver::TextAreaAI - driver for the TextAreaAI dynamic field

=head1 DESCRIPTION

DynamicFields TextAreaAI Driver delegate

=head1 PUBLIC INTERFACE

This module implements the public interface of L<Kernel::System::DynamicField::Backend>.
Please look there for a detailed reference of the functions.

=head2 new()

usually, you want to create an instance of this
by using Kernel::System::DynamicField::Backend->new();

=cut

sub new {
    my ($Type) = @_;

    # Call constructor of the base class.
    my $Self = $Type->SUPER::new;

    # Settings that are specific to the TextAreaAI dynamic field
    $Self->{Behaviors}{IsCustomerInterfaceCapable} = 0;
    $Self->{Behaviors}{IsSetCapable}               = 0;
    $Self->{Behaviors}{IsStatsCondition}           = 0;

    return $Self;
}

sub ValueSet {
    my ( $Self, %Param ) = @_;

    if ( !$Param{DoWrite} ) {
        return 1;
    }

    return $Self->SUPER::ValueSet(%Param);
}

sub EditFieldValueGet {
    my ( $Self, %Param ) = @_;

    # this field is intended to be readonly and therefor must never have an EditFieldValue
    return;
}

sub EditFieldRender {
    my ( $Self, %Param ) = @_;

    # take config from field config
    my $FieldConfig = $Param{DynamicFieldConfig}{Config};
    my $FieldName   = 'DynamicField_' . $Param{DynamicFieldConfig}{Name};
    my $FieldLabel  = $Param{DynamicFieldConfig}{Label};

    my $Value = '';

    # set the field value or default
    if ( $Param{UseDefaultValue} ) {
        $Value = $FieldConfig->{DefaultValue} // '';
    }
    $Value = $Param{Value} // $Value;

    # extract the dynamic field value from the web request
    my $FieldValue = $Self->EditFieldValueGet(
        %Param,
    );

    if ( defined $FieldValue ) {
        $Value = $FieldValue;
    }

    if ( !ref $Value ) {
        $Value = [$Value];
    }
    elsif ( !$Value->@* ) {
        $Value = [undef];
    }

    # set the rows number
    my $RowsNumber = defined $FieldConfig->{Rows} && $FieldConfig->{Rows} ? $FieldConfig->{Rows} : '7';

    # set the cols number
    my $ColsNumber = defined $FieldConfig->{Cols} && $FieldConfig->{Cols} ? $FieldConfig->{Cols} : '42';

    # check and set class if necessary
    my $FieldClass = 'DynamicFieldTextArea';
    if ( defined $Param{Class} && $Param{Class} ne '' ) {
        $FieldClass .= ' ' . $Param{Class};
    }

    # set classes according to mandatory and acl hidden params
    if ( $Param{ACLHidden} && $Param{Mandatory} ) {
        $FieldClass .= ' Validate_Required_IfVisible';
    }
    elsif ( $Param{Mandatory} ) {
        $FieldClass .= ' Validate_Required';
    }

    # set error css class
    if ( $Param{ServerError} ) {
        $FieldClass .= ' ServerError';
    }

    # set validation class for maximum characters
    $FieldClass .= ' Validate_MaxLength';

    my $FieldLabelEscaped = $Param{LayoutObject}->Ascii2Html(
        Text => $Param{LayoutObject}{LanguageObject}->Translate($FieldLabel),
    );

    # create field HTML
    # the XHTML definition does not support maxlength attribute for a text-area field,
    # we use data-maxlength instead
    # Notice that some browsers count new lines \n\r as only 1 character. In these cases the
    # validation framework might generate an error while the user is still capable to enter text in the
    # text-area. Otherwise the maxlength property will prevent to enter more text than the maximum.
    my $MaxLength = $Param{MaxLength} // $Self->{MaxLength};

    my $ErrorMessage1 = $Param{LayoutObject}{LanguageObject}->Translate("This field is required or");
    my $ErrorMessage2 = $Param{LayoutObject}{LanguageObject}->Translate("The field content is too long!");
    my $ErrorMessage3 = $Param{LayoutObject}{LanguageObject}->Translate( "Maximum size is %s characters.", $MaxLength );

    my %FieldTemplateData = (
        FieldClass        => $FieldClass,
        FieldName         => $FieldName,
        FieldLabelEscaped => $FieldLabelEscaped,
        Readonly          => $Param{Readonly},
        RowsNumber        => $RowsNumber,
        ColsNumber        => $ColsNumber,
        MaxLength         => $MaxLength,
        ErrorMessage1     => $ErrorMessage1,
        ErrorMessage2     => $ErrorMessage2,
        ErrorMessage3     => $ErrorMessage3,
        DivID             => $FieldName . 'Error',
    );

    my $FieldTemplateFile = 'DynamicField/Agent/TextArea';

    my %Error = (
        ServerError => $Param{ServerError},
        Mandatory   => $Param{Mandatory},
    );
    my @ResultHTML;
    for my $ValueIndex ( 0 .. $#{$Value} ) {
        $FieldTemplateData{FieldID}      = $FieldConfig->{MultiValue} ? $FieldName . '_' . $ValueIndex : $FieldName;
        $FieldTemplateData{ValueEscaped} = $Param{LayoutObject}->Ascii2Html(
            Text => $Value->[$ValueIndex],
        );

        if ( !$ValueIndex ) {
            if ( $Error{ServerError} ) {
                $Error{DivIDServerError} = $FieldTemplateData{FieldID} . 'ServerError';
                $Error{ErrorMessage}     = Translatable( $Param{ErrorMessage} || 'This field is required.' );
            }
            if ( $Error{Mandatory} ) {
                $Error{DivIDMandatory}       = $FieldTemplateData{FieldID} . 'Error';
                $Error{FieldRequiredMessage} = Translatable('This field is required.');
            }
        }

        push @ResultHTML, $Param{LayoutObject}->Output(
            TemplateFile => $FieldTemplateFile,
            Data         => {
                %FieldTemplateData,
                %Error,
            },
        );
    }

    # call EditLabelRender on the common Driver
    my $LabelString = $Self->EditLabelRender(
        %Param,
        Mandatory => $Param{Mandatory} || '0',
        FieldName => $FieldName,
    );

    my $Data = {
        Label => $LabelString,
        Field => $ResultHTML[0],
    };

    return $Data;
}

sub GetFieldTypeSettings {
    my ( $Self, %Param ) = @_;

    return ();
}

1;
