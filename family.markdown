### [% surnames.join( ' / ' ) %]

[% IF address.street %]**[% address.street %], [% address.postcode %] [% address.city %]**[%- END %]
[%- IF address.street && home_phones.size > 0 %] / [%- END %]
[%- IF home_phones.size > 0 %]**[% home_phones.join( ', ' ) %]**[%- END %]

[% FOREACH card IN cards %]
[% card.firstname %] [% card.surname %] ([% card.title %])
[%- IF card.birthday %] geb. [% card.birthday %][% END %]
[%- IF card.phone_cell %] [% card.phone_cell %][% END %]
[%- IF card.email %] | [% card.email %][% END %]
[% END %][%# end cards %]

