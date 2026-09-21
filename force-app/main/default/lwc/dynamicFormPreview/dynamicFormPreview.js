import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getFormSchema from '@salesforce/apex/DynamicFormSchemaService.getFormSchema';
import submitForm from '@salesforce/apex/DynamicFormSubmissionService.submitForm';

/**
 * dynamicFormPreview
 * ---------------------
 * Placed on the Form_Configuration__c record page itself. Renders the
 * configured form exactly as an end user would see it (reusing
 * dynamicFormSection/dynamicFormField) and submits for real via
 * DynamicFormSubmissionService - this is a live rehearsal of the form,
 * not a dry run. An optional "Preview against a sample record" input lets
 * the admin test Update-mode prefill against a real record before wiring
 * the form up elsewhere; submitting while that's populated will genuinely
 * update that record, the same as a real end-user submission would.
 *
 * A manual Refresh control re-fetches the schema, since the underlying
 * Apex method is cacheable - editing a Form_Field_Configuration__c record
 * in another tab/window won't be picked up here automatically.
 */
export default class DynamicFormPreview extends LightningElement {
    @api recordId; // the Form_Configuration__c's own Id, auto-injected by the record page

    @track fieldValues = {};
    @track hiddenFieldApiNames = [];
    @track requiredOverrides = {};
    @track sampleRecordId = null;
    @track validationErrors = [];

    schema;
    wiredSchemaResult;
    errorMessage;
    successMessage;
    isSubmitting = false;

    @wire(getFormSchema, { formConfigId: '$recordId', recordId: '$sampleRecordId' })
    wiredForm(result) {
        this.wiredSchemaResult = result;
        const { data, error } = result;
        if (data) {
            this.schema = data;
            this.errorMessage = undefined;
            this.resetFieldValues();
        } else if (error) {
            this.schema = undefined;
            this.errorMessage = error?.body?.message || 'Unable to load this form for preview.';
        }
    }

    get sections() {
        return this.schema?.sections || [];
    }

    get formTitle() {
        return this.schema?.formTitle || '';
    }

    get modeLabel() {
        return this.schema?.mode === 'Update' ? 'Update (prefilled from sample record)' : 'Insert (blank form)';
    }

    get submitButtonLabel() {
        return this.schema?.mode === 'Update' ? this.schema?.updateButtonLabel : this.schema?.insertButtonLabel;
    }

    get hasValidationErrors() {
        return this.validationErrors.length > 0;
    }

    resetFieldValues() {
        const values = {};
        for (const section of this.sections) {
            for (const field of section.fields) {
                if (field.currentValue !== undefined && field.currentValue !== null) {
                    values[field.apiName] = field.currentValue;
                } else if (field.defaultValue) {
                    values[field.apiName] = field.defaultValue;
                }
            }
        }
        this.fieldValues = values;
        this.successMessage = undefined;
        this.evaluateConditionalRules();
    }

    handleSampleRecordIdChange(event) {
        const trimmed = event.target.value?.trim();
        this.sampleRecordId = trimmed ? trimmed : null;
    }

    handleFieldChange(event) {
        const { apiName, value } = event.detail;
        this.fieldValues = { ...this.fieldValues, [apiName]: value };
        this.evaluateConditionalRules();
    }

    handleRefresh() {
        this.errorMessage = undefined;
        this.successMessage = undefined;
        return refreshApex(this.wiredSchemaResult);
    }

    evaluateConditionalRules() {
        const hidden = [];
        const requiredOverrides = {};
        for (const section of this.sections) {
            for (const field of section.fields) {
                if (!field.conditionalRulesJson) continue;
                let rule;
                try {
                    rule = JSON.parse(field.conditionalRulesJson);
                } catch (e) {
                    continue;
                }
                const actual = this.fieldValues[rule.controllingField];
                const met = rule.operator === 'notEquals' ? actual !== rule.value : actual === rule.value;
                if (rule.action === 'hide' && met) hidden.push(field.apiName);
                if (rule.action === 'show' && !met) hidden.push(field.apiName);
                if (rule.action === 'require') requiredOverrides[field.apiName] = met;
            }
        }
        this.hiddenFieldApiNames = hidden;
        this.requiredOverrides = requiredOverrides;
    }

    validateBeforeSubmit() {
        const errors = [];
        for (const section of this.sections) {
            for (const field of section.fields) {
                if (this.hiddenFieldApiNames.includes(field.apiName)) continue;
                const isRequired = Object.prototype.hasOwnProperty.call(this.requiredOverrides, field.apiName)
                    ? this.requiredOverrides[field.apiName]
                    : field.required;
                const value = this.fieldValues[field.apiName];
                const isEmpty = value === undefined || value === null || value === '';

                if (isRequired && isEmpty && !this.schema.disableValidations) {
                    errors.push(`"${field.label}" is required.`);
                    continue;
                }
                if (field.validationPattern && !isEmpty && !this.schema.disableValidations) {
                    const regex = new RegExp(field.validationPattern);
                    if (!regex.test(String(value))) {
                        errors.push(field.validationError || `"${field.label}" is not valid.`);
                    }
                }
            }
        }
        this.validationErrors = errors;
        return errors.length === 0;
    }

    async handleSubmit() {
        this.errorMessage = undefined;
        this.successMessage = undefined;
        if (!this.validateBeforeSubmit()) {
            return;
        }

        this.isSubmitting = true;
        try {
            const result = await submitForm({
                formConfigId: this.schema.formConfigId,
                existingRecordId: this.schema.recordId,
                fieldValues: this.fieldValues
            });
            if (result.success) {
                this.successMessage = result.message;
                await refreshApex(this.wiredSchemaResult);
            } else {
                this.errorMessage = result.errorMessage;
            }
        } catch (e) {
            this.errorMessage = e?.body?.message || 'Submission failed.';
        } finally {
            this.isSubmitting = false;
        }
    }
}