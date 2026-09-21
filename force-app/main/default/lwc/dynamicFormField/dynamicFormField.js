import { LightningElement, api } from 'lwc';

/**
 * dynamicFormField
 * -----------------
 * Renders exactly one field's input control based on its resolved dataType
 * (from DynamicFormWrappers.FieldSchema). Purely presentational - it holds
 * no server calls and no knowledge of sibling fields; conditional
 * visibility/required-ness is decided by the parent (dynamicFormSection /
 * dynamicFormEngine) and passed down via the `hidden` and `forcedRequired`
 * properties.
 *
 * Fires a `fieldchange` CustomEvent with detail:
 *   { apiName: String, value: any }
 * for every field it renders - including each of the five sub-inputs an
 * Address field expands into, so the parent's fieldValues map always keys
 * by the real target-object field API name, never a compound alias.
 */
export default class DynamicFormField extends LightningElement {
    @api field;          // DynamicFormWrappers.FieldSchema, serialized from Apex
    @api value;           // current value for non-Address types
    @api hidden = false;  // set by parent based on Conditional_Rules__c evaluation
    @api forcedRequired;  // set by parent when a conditional rule requires this field

    // ---- Address sub-values (only used when field.dataType === 'Address') ----
    _addressValues = { street: '', city: '', state: '', postalCode: '', country: '' };

    get isRequired() {
        return this.forcedRequired !== undefined ? this.forcedRequired : this.field?.required;
    }

    get isReadOnly() {
        return this.field?.readOnly;
    }

    get baseFieldNameWithoutAddress() {
        return this.field?.apiName ? this.field.apiName.replace(/Address$/, '') : '';
    }

    // ---- Type checks used by the template's if:true directives ----
    get isText() { return this.field?.dataType === 'Text'; }
    get isEmail() { return this.field?.dataType === 'Email'; }
    get isPassword() { return this.field?.dataType === 'Password'; }
    get isNumber() { return this.field?.dataType === 'Number'; }
    get isCurrency() { return this.field?.dataType === 'Currency'; }
    get isDate() { return this.field?.dataType === 'Date'; }
    get isDateTime() { return this.field?.dataType === 'DateTime'; }
    get isCheckbox() { return this.field?.dataType === 'Checkbox'; }
    get isLongTextArea() { return this.field?.dataType === 'Long Text Area'; }
    get isPicklist() { return this.field?.dataType === 'Picklist'; }
    get isMultiSelect() { return this.field?.dataType === 'Multi-Select Picklist'; }
    get isLookup() { return this.field?.dataType === 'Lookup'; }
    get isAddress() { return this.field?.dataType === 'Address'; }

    get comboboxOptions() {
        return (this.field?.options || []).map((o) => ({ label: o.label, value: o.value }));
    }

    handleSimpleChange(event) {
        this.dispatchFieldChange(this.field.apiName, event.target.value);
    }

    handleCheckboxChange(event) {
        this.dispatchFieldChange(this.field.apiName, event.target.checked);
    }

    handleMultiSelectChange(event) {
        this.dispatchFieldChange(this.field.apiName, event.detail.value); // array of selected values
    }

    handleLookupChange(event) {
        this.dispatchFieldChange(this.field.apiName, event.detail.recordId);
    }

    handleAddressPartChange(event) {
        const part = event.target.dataset.part; // street | city | state | postalCode | country
        const suffixMap = { street: 'Street', city: 'City', state: 'State', postalCode: 'PostalCode', country: 'Country' };
        const targetFieldApiName = this.baseFieldNameWithoutAddress + suffixMap[part];
        this.dispatchFieldChange(targetFieldApiName, event.target.value);
    }

    dispatchFieldChange(apiName, value) {
        this.dispatchEvent(
            new CustomEvent('fieldchange', {
                detail: { apiName, value }
            })
        );
    }
}