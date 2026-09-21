import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getFormSchema from '@salesforce/apex/DynamicFormSchemaService.getFormSchema';
import submitForm from '@salesforce/apex/DynamicFormSubmissionService.submitForm';
import submitComposite from '@salesforce/apex/DynamicFormSubmissionService.submitComposite';

/**
 * dynamicFormEngine
 * -------------------
 * Top-level orchestrator for the Dynamic Form Builder. Responsible for:
 *  - fetching the resolved schema (DynamicFormSchemaService.getFormSchema)
 *  - driving the composite multi-step wizard, when the form is composite
 *  - evaluating each field's Conditional_Rules__c against live form state
 *  - client-side validation (mirrors, but does not replace, server checks)
 *  - submitting via DynamicFormSubmissionService (single or composite)
 *
 * formConfigId is chosen at design time in Lightning App Builder via the
 * FormConfigurationPicklist Dynamic Picklist (see the .js-meta.xml) - the
 * component renders that form directly with no runtime picker in the UI.
 *
 * Placed on a Record Page, @api recordId is populated automatically by the
 * platform whenever the object type matches the configured form.
 */
export default class DynamicFormEngine extends LightningElement {
    @api recordId = null;   // auto-populated on a matching Record Page
    @api formConfigId;      // set via the App Builder design-time picklist

    @track fieldValues = {};          // apiName -> current value, for the step being displayed
    @track hiddenFieldApiNames = [];  // fields hidden by a conditional rule, for the step being displayed
    @track requiredOverrides = {};    // apiName -> boolean, for rule-driven required-ness

    schema;                     // DynamicFormWrappers.FormSchema (or master schema, for composite)
    wiredSchemaResult;          // retained for refreshApex after a successful submit
    currentStepIndex = 0;       // used only when schema.isComposite
    stepFieldValuesByOrder = {}; // stepOrder -> saved fieldValues, so Back/retry restores state
    committedStepRecordIds = {}; // stepOrder -> Id, accumulated across composite attempts (for retry)

    isSubmitting = false;
    isDone = false;
    successMessage;
    errorMessage;
    validationErrors = [];

    @wire(getFormSchema, { formConfigId: '$formConfigId', recordId: '$recordId' })
    wiredForm(result) {
        this.wiredSchemaResult = result;
        const { data, error } = result;
        if (data) {
            this.schema = data;
            this.errorMessage = undefined;
            this.initializeFieldValuesForCurrentStep();
        } else if (error) {
            this.schema = undefined;
            this.errorMessage = this.extractErrorMessage(error);
        }
    }

    // -----------------------------------------------------------------
    // Derived state
    // -----------------------------------------------------------------

    get isComposite() {
        return !!this.schema?.isComposite;
    }

    get activeStepSchema() {
        if (!this.schema) return undefined;
        if (!this.isComposite) return this.schema;
        return this.schema.compositeSteps?.[this.currentStepIndex]?.stepSchema;
    }

    // Safe accessor for the card title - never throws when schema hasn't
    // loaded yet, unlike binding activeStepSchema.formTitle directly in the template.
    get cardTitle() {
        return this.activeStepSchema ? this.activeStepSchema.formTitle : 'Loading form...';
    }

    get activeSections() {
        return this.activeStepSchema?.sections || [];
    }

    get isFirstStep() {
        return this.currentStepIndex === 0;
    }

    get isLastStep() {
        return !this.isComposite || this.currentStepIndex === (this.schema?.compositeSteps?.length || 1) - 1;
    }

    get submitButtonLabel() {
        if (this.isComposite && !this.isLastStep) return 'Next';
        return this.activeStepSchema?.mode === 'Update'
            ? this.activeStepSchema?.updateButtonLabel
            : this.activeStepSchema?.insertButtonLabel;
    }

    get stepProgressLabel() {
        if (!this.isComposite) return '';
        return `Step ${this.currentStepIndex + 1} of ${this.schema.compositeSteps.length}`;
    }

    get hasValidationErrors() {
        return this.validationErrors.length > 0;
    }

    // -----------------------------------------------------------------
    // Field value handling + conditional rules
    // -----------------------------------------------------------------

    initializeFieldValuesForCurrentStep() {
        const restored = this.stepFieldValuesByOrder[this.currentStepIndex + 1];
        if (restored) {
            this.fieldValues = { ...restored };
        } else {
            const values = {};
            for (const section of this.activeSections) {
                for (const field of section.fields) {
                    if (field.currentValue !== undefined && field.currentValue !== null) {
                        values[field.apiName] = field.currentValue;
                    } else if (field.defaultValue) {
                        values[field.apiName] = field.defaultValue;
                    }
                }
            }
            this.fieldValues = values;
        }
        this.evaluateConditionalRules();
    }

    handleFieldChange(event) {
        const { apiName, value } = event.detail;
        this.fieldValues = { ...this.fieldValues, [apiName]: value };
        this.evaluateConditionalRules();
    }

    /**
     * Supported rule shape (stored per-field in Conditional_Rules__c):
     *   { "controllingField": "BillingCountry", "operator": "equals",
     *     "value": "USA", "action": "require" | "hide" }
     * Kept intentionally simple for v1 - a single condition per field.
     */
    evaluateConditionalRules() {
        const hidden = [];
        const requiredOverrides = {};

        for (const section of this.activeSections) {
            for (const field of section.fields) {
                if (!field.conditionalRulesJson) continue;
                let rule;
                try {
                    rule = JSON.parse(field.conditionalRulesJson);
                } catch (e) {
                    continue; // malformed rule - fail safe, treat field as unconditional
                }
                const controllingValue = this.fieldValues[rule.controllingField];
                const conditionMet = this.evaluateOperator(controllingValue, rule.operator, rule.value);

                if (rule.action === 'hide') {
                    if (conditionMet) hidden.push(field.apiName);
                } else if (rule.action === 'show') {
                    if (!conditionMet) hidden.push(field.apiName);
                } else if (rule.action === 'require') {
                    requiredOverrides[field.apiName] = conditionMet;
                }
            }
        }
        this.hiddenFieldApiNames = hidden;
        this.requiredOverrides = requiredOverrides;
    }

    evaluateOperator(actualValue, operator, expectedValue) {
        switch (operator) {
            case 'notEquals':
                return actualValue !== expectedValue;
            case 'equals':
            default:
                return actualValue === expectedValue;
        }
    }

    // -----------------------------------------------------------------
    // Validation (client-side mirror of the server's enforcement)
    // -----------------------------------------------------------------

    validateActiveStep() {
        const errors = [];
        for (const section of this.activeSections) {
            for (const field of section.fields) {
                if (this.hiddenFieldApiNames.includes(field.apiName)) continue; // hidden fields are never required

                const isRequired = Object.prototype.hasOwnProperty.call(this.requiredOverrides, field.apiName)
                    ? this.requiredOverrides[field.apiName]
                    : field.required;
                const value = this.fieldValues[field.apiName];
                const isEmpty = value === undefined || value === null || value === '';

                if (isRequired && isEmpty && !this.activeStepSchema.disableValidations) {
                    errors.push(`"${field.label}" is required.`);
                    continue;
                }
                if (field.validationPattern && !isEmpty && !this.activeStepSchema.disableValidations) {
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

    // -----------------------------------------------------------------
    // Navigation (composite wizard) + submission
    // -----------------------------------------------------------------

    handleBack() {
        this.stepFieldValuesByOrder[this.currentStepIndex + 1] = { ...this.fieldValues };
        this.currentStepIndex -= 1;
        this.initializeFieldValuesForCurrentStep();
    }

    async handleSubmit() {
        if (!this.validateActiveStep()) {
            return;
        }
        this.stepFieldValuesByOrder[this.currentStepIndex + 1] = { ...this.fieldValues };

        if (this.isComposite && !this.isLastStep) {
            this.currentStepIndex += 1;
            this.initializeFieldValuesForCurrentStep();
            return;
        }

        this.isSubmitting = true;
        this.errorMessage = undefined;

        try {
            if (this.isComposite) {
                await this.submitCompositeForm();
            } else {
                await this.submitSingleForm();
            }
        } finally {
            this.isSubmitting = false;
        }
    }

    async submitSingleForm() {
        const result = await submitForm({
            formConfigId: this.schema.formConfigId,
            existingRecordId: this.schema.recordId,
            fieldValues: this.fieldValues
        });
        if (result.success) {
            this.isDone = true;
            this.successMessage = result.message;
            return refreshApex(this.wiredSchemaResult);
        }
        this.errorMessage = result.errorMessage;
        return undefined;
    }

    async submitCompositeForm() {
        const steps = this.schema.compositeSteps.map((step) => ({
            formConfigId: step.formConfigId,
            stepOrder: step.stepOrder,
            // A step already committed on a prior attempt (retry mode) is
            // resubmitted as an Update using its known Id - the service
            // treats this as a safe no-op-ish resave rather than a duplicate insert.
            existingRecordId: this.committedStepRecordIds[step.stepOrder] || null,
            fieldValues: this.stepFieldValuesByOrder[step.stepOrder] || {}
        }));

        const result = await submitComposite({
            masterFormConfigId: this.schema.formConfigId,
            steps
        });

        if (result.success) {
            this.isDone = true;
            this.successMessage = 'All steps submitted successfully.';
            this.committedStepRecordIds = { ...result.committedRecordIdsByStep };
            return refreshApex(this.wiredSchemaResult);
        }

        // Failure: keep whatever committed (Retry mode) or nothing (Rollback mode),
        // jump the wizard back to the failed step so the user can correct it.
        this.committedStepRecordIds = { ...result.committedRecordIdsByStep };
        this.errorMessage = result.errorMessage;
        this.currentStepIndex = result.failedStepOrder - 1;
        this.initializeFieldValuesForCurrentStep();
        return undefined;
    }

    extractErrorMessage(error) {
        return error?.body?.message || error?.message || 'An unexpected error occurred.';
    }
}