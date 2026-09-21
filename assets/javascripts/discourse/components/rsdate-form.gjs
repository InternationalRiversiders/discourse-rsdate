import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
export default class extends Component {
  @service dialog;
  @tracked busy = false;
  @tracked error = "";
  key = null;
  fingerprint = null;
  @action async submit(event) {
    event.preventDefault();
    if (this.busy) {
      return;
    }
    if (this.args.form.confirm && !(await new Promise((resolve) => this.dialog.confirm({message:this.args.form.confirm,didConfirm:()=>resolve(true),didCancel:()=>resolve(false)})))) { return; }
    this.busy = true;
    this.error = "";
    const values = Object.fromEntries(new FormData(event.target));
    for (const field of this.args.form.fields) {
      if (field.type === "checkbox") {
        values[field.name] = values[field.name] === "on";
      }
    }
    const data = { ...this.args.form.data, ...values };
    const fingerprint = JSON.stringify(data);
    if (fingerprint !== this.fingerprint) {
      this.key = crypto.randomUUID();
      this.fingerprint = fingerprint;
    }
    try {
      await this.args.execute(this.args.form.operation, data, this.key);
      this.key = null;
      this.fingerprint = null;
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  get groups() {
    const fields = this.args.form.fields;
    let definitions = [];
    if (this.args.form.operation === "profile") {
      definitions = [
        [
          "先认识你",
          "填写基本资料，让认识从真诚开始。",
          ["nickname", "gender", "target_gender", "grade", "campus"],
        ],
        [
          "你的生活",
          "比起标签，我们更想了解真实的你。",
          ["mbti", "zodiac", "interests", "schedule", "bio"],
        ],

      ];
    }
    if (!definitions.length) {
      return [{ title: "", fields }];
    }
    return definitions.map(([title, description, names]) => ({
      title,
      description,
      fields: fields.filter((field) => names.includes(field.name)),
    }));
  }
  get hasRequired() {
    return this.args.form.fields.some((field) => field.required);
  }
  <template>
    <form
      class="river-form"
      aria-busy={{this.busy}}
      {{on "submit" this.submit}}
    >
      <div class="river-form-heading">{{#if @form.title}}<h3
          >{{@form.title}}</h3>{{/if}}{{#if this.hasRequired}}<span>* 为必填项</span>{{/if}}</div>
      {{#each this.groups key="title" as |group|}}
        <fieldset
          class="river-fieldset"
          aria-label={{if group.title group.title @form.title}}
        >
          {{#if group.title}}<legend>{{group.title}}</legend><p
              class="river-fieldset-note"
            >{{group.description}}</p>{{/if}}
          <div class="river-fields">{{#each group.fields key="name" as |field|}}
              <label
                class="{{if (eq field.type 'textarea') 'river-field-wide'}}
                  {{if (eq field.type 'checkbox') 'river-checkbox'}}
                  {{if
                    (eq field.type 'upload')
                    'river-field-wide river-upload'
                  }}"
              >
                <span>{{field.label}}{{#if field.required}}<span
                      class="river-required"
                      aria-hidden="true"
                    > *</span>{{/if}}</span>
                {{#if (eq field.type "textarea")}}<textarea
                    name={{field.name}}
                    aria-label={{field.label}}
                    required={{field.required}}
                    rows="4"
                    maxlength={{field.maxlength}}
                    minlength={{field.minlength}}
                  >{{field.value}}</textarea>
                {{else if (eq field.type "select")}}<select
                    name={{field.name}}
                    aria-label={{field.label}}
                    required={{field.required}}
                  >{{#each field.options as |choice|}}<option
                        value={{choice.value}}
                        selected={{eq choice.value field.value}}
                      >{{choice.label}}</option>{{/each}}</select>
                {{else if (eq field.type "checkbox")}}<input
                    type="checkbox"
                    name={{field.name}}
                    aria-label={{field.label}}
                    checked={{field.value}}
                  />
                {{else}}<input
                    type={{field.type}}
                    name={{field.name}}
                    aria-label={{field.label}}
                    value={{field.value}}
                    required={{field.required}}
                    min={{field.min}}
                    max={{field.max}}
                    step="1"
                    maxlength={{field.maxlength}}
                    minlength={{field.minlength}}
                  />{{/if}}
                {{#if field.hint}}<small class="river-field-hint">{{field.hint}}</small>{{/if}}
              </label>
            {{/each}}</div>
        </fieldset>
      {{/each}}
      {{#if this.error}}<p
          role="alert"
          class="river-error"
        >{{this.error}}</p>{{/if}}
      <div class="river-form-footer"><button
          class="btn btn-primary"
          type="submit"
          disabled={{this.busy}}
        >{{if this.busy "正在保存…" @form.button}}</button></div>
    </form>
  </template>
}
