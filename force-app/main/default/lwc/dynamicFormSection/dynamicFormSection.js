import { LightningElement, api } from 'lwc';

/**
 * dynamicFormSection
 * --------------------
 * Renders one section's heading/description and lays out its fields in
 * either a 1-column or 2-column SLDS grid. Holds no logic of its own for
 * validation or conditional rules - it receives the already-computed
 * hidden/required overrides from dynamicFormEngine and simply forwards
 * each field's `fieldchange` event upward untouched.
 */
export default class DynamicFormSection extends LightningElement {
    @api section;              // DynamicFormWrappers.SectionSchema, serialized from Apex
    @api fieldValues = {};     // Map<apiName, value> - current values for every field on the form
    @api hiddenFieldApiNames = []; // fields currently hidden by a conditional rule
    @api requiredOverrides = {};   // Map<apiName, boolean> - fields whose required-ness a rule changed

    get isTwoColumn() {
        return this.section?.displayLayout === '2-Column';
    }

    get columnClass() {
        return this.isTwoColumn ? 'slds-col slds-size_1-of-2 slds-p-around_x-small'
                                 : 'slds-col slds-size_1-of-1 slds-p-around_x-small';
    }

    get fieldsWithState() {
        return (this.section?.fields || []).map((field) => ({
            field,
            key: field.apiName,
            value: this.fieldValues[field.apiName],
            hidden: this.hiddenFieldApiNames.includes(field.apiName),
            forcedRequired: Object.prototype.hasOwnProperty.call(this.requiredOverrides, field.apiName)
                ? this.requiredOverrides[field.apiName]
                : field.required
        }));
    }

    // Field-level changes bubble straight up - dynamicFormEngine owns the
    // single source of truth for fieldValues and re-runs rule evaluation.
    handleFieldChange(event) {
        this.dispatchEvent(
            new CustomEvent('fieldchange', {
                detail: event.detail
            })
        );
    }
}