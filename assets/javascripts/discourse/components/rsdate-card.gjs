import { formatDateTime } from "../lib/campus-time";
import ForumUser from "./rsdate-user";
import DUserAvatar from "discourse/ui-kit/d-user-avatar";
import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import AppForm from "./rsdate-form";
import AppIcon from "./rsdate-icon";
const href = (query) => "/rsdate?" + new URLSearchParams(query).toString();
export default class extends Component {
  get initial() {
    return Array.from(this.args.card.title || "")
      .slice(0, 1)
      .join("");
  }
  <template>
    <article class="river-card" data-card-id={{@card.id}}>
      <div class="river-card-heading">
        <div class="river-card-symbol">{{#if @card.account}}<DUserAvatar @user={{@card.account}} @size="medium" />{{else}}<span aria-hidden="true">{{this.initial}}</span>{{/if}}</div>
        <div class="river-card-heading-text">{{#if @card.tag}}<span
              class="river-tag"
            >{{@card.tag}}</span>{{/if}}
          <h2>{{@card.title}}</h2>{{#if @card.subtitle}}<p
              class="river-meta"
            >{{@card.subtitle}}</p>{{/if}}
        </div>
      </div>
      {{#if @card.created_at}}<p class="river-meta">{{@card.time_label}} <time datetime={{@card.created_at}}>{{formatDateTime @card.created_at}}</time></p>{{/if}}
      {{#if @card.images}}<div class="river-images">{{#each
            @card.images
            as |url|
          }}<a href={{url}} target="_blank" rel="noopener"><img
                src={{url}}
                alt={{@card.title}}
                loading="lazy"
              /></a>{{/each}}</div>{{/if}}
      {{#if @card.body}}<p class="river-body">{{@card.body}}</p>{{/if}}
      {{#if @card.metrics}}<dl class="river-metrics">{{#each
            @card.metrics
            as |metric|
          }}<div><dt>{{metric.label}}</dt><dd
              >{{metric.value}}</dd></div>{{/each}}</dl>{{/if}}
      {{#if @card.account}}<ForumUser @user={{@card.account}} @hideAvatar={{true}} />{{/if}}
      {{#if @card.detail_note}}<p class="river-match-note">{{@card.detail_note}}</p>{{/if}}
      {{#if @card.empty_detail}}<p class="river-meta">{{@card.empty_detail}}</p>{{/if}}
      {{#if @card.links.length}}<div class="river-card-links">{{#each
            @card.links
            as |link|
          }}<a
              href={{href link.query}}
              {{on "click" (fn @navigate link.query)}}
            >{{link.label}}<AppIcon @kind="arrow" /></a>{{/each}}</div>{{/if}}
      {{#if @card.actions.length}}<div class="river-actions">{{#each
            @card.actions
            as |item|
          }}<button
              class="btn btn-default btn-small"
              type="button"
              disabled={{@busy}}
              {{on "click" (fn @button item)}}
            >{{item.label}}</button>{{/each}}</div>{{/if}}
      {{#each @card.forms as |form|}}<details
          class="river-discussion-form"
        ><summary>{{if form.title form.title "回复"}}</summary><AppForm
            @form={{form}}
            @execute={{@execute}}
          /></details>{{/each}}
    </article>
  </template>
}
