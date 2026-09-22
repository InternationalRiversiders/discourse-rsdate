import { formatDateTime } from "../lib/campus-time";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import AppForm from "./rsdate-form";
import AppCard from "./rsdate-card";
import AppIcon from "./rsdate-icon";

export default class extends Component {
  @service dialog;
  mount = modifier(() => {
    const listener = () => this.navigate(Object.fromEntries(new URLSearchParams(window.location.search)), null, true);
    window.addEventListener("popstate", listener);
    return () => window.removeEventListener("popstate", listener);
  });
  @tracked snapshot;
  @tracked busy = false;
  @tracked error = "";
  @tracked notice = "";
  get data() {
    return this.snapshot || this.args.model;
  }
  get query() {
    return new URLSearchParams(window.location.search);
  }
  @action async navigate(query, event, fromHistory = false) {
    if (
      event &&
      (event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey ||
        event.button > 0)
    ) {
      return;
    }
    event?.preventDefault();
    this.busy = true;
    this.error = "";
    this.notice = "";
    try {
      const search = new URLSearchParams(query).toString();
      this.snapshot = await ajax("/rsdate/state.json?" + search);
      if (!fromHistory && window.location.search !== "?" + search) { window.history.pushState({}, "", "/rsdate?" + search); }
      window.scrollTo({ top: 0, behavior: "auto" });
    } catch (e) {
      this.error = extractError(e);
    } finally {
      this.busy = false;
    }
  }
  @action tab(id, e) {
    return this.navigate({ view: id }, e);
  }
  @action async search(e) {
    e.preventDefault();
    const query = Object.fromEntries(new FormData(e.target));
    query.view = this.data.view;
    if (this.query.get("part")) { query.part = this.query.get("part"); }
    return this.navigate(query);
  }
  @action async execute(op, data, requestId) {
    this.error = "";
    this.notice = "";
    const result = await ajax("/rsdate/action", {
      type: "POST",
      contentType: "application/json",
      data: JSON.stringify({ operation: op, data, request_id: requestId }),
    });
    if (result.query) { await this.navigate(result.query); }
    else { this.snapshot = await ajax("/rsdate/state.json?" + this.query.toString()); }
    this.notice = result.message || "已保存";
    return result;
  }
  @action async button(item) {
    if (this.busy) {
      return;
    }
    if (item.confirm && !(await new Promise((resolve) => this.dialog.confirm({message:item.confirm,didConfirm:()=>resolve(true),didCancel:()=>resolve(false)})))) { return; }
    this.busy = true;
    try {
      await this.execute(item.operation, item.data, crypto.randomUUID());
    } catch (e) {
      this.error = extractError(e);
    } finally {
      this.busy = false;
    }
  }
  get isDetail() { return ["module", "results"].includes(this.data.view); }
  get hasCards() {
    return Boolean(this.data.cards?.length);
  }
  get hasForms() {
    return Boolean(this.data.forms?.length);
  }
  get showEmpty() {
    return !this.hasCards && !this.hasForms;
  }
  get workspaceClass() {
    return `river-workspace ${this.isDetail ? "is-detail" : ""} ${this.hasForms ? "has-forms" : ""} ${!this.hasCards && this.hasForms ? "form-only" : ""}`;
  }
  get currentTitle() { return this.data.heading || this.data.tabs.find((tab) => tab.id === this.data.view)?.label || "RSDate"; }
  get primaryFilter() {
    return this.data.filters[0];
  }
  get extraFilters() {
    return this.data.filters.slice(1);
  }
  get activeFilters() {
    return this.extraFilters.some((field) => Boolean(field.value));
  }
  get showAction() {
    return (
      this.data.member && !this.data.readonly &&
      this.data.view !== "questions" &&
      this.data.view !== "admin"
    );
  }
  @action primaryAction(event) {
    return this.navigate({ view: "questions" }, event);
  }
  <template>
    <main
      class="river-app river-rsdate"
      data-view={{this.data.view}}
      aria-busy={{this.busy}}
      {{this.mount}}
    >
      <header class="river-hero">
        <div class="river-hero-copy"><span class="river-eyebrow"><span
              class="river-brand-dot"
            ></span>RIVERSIDE / CONNECTIONS</span><h1>{{this.data.title}}</h1><p
          >{{this.data.intro}}</p>
          {{#if this.showAction}}<button
              class="river-hero-action"
              type="button"
              disabled={{this.busy}}
              {{on "click" this.primaryAction}}
            >填写问卷<AppIcon @kind="arrow" /></button>{{/if}}
        </div>
        <div class="river-hero-art" aria-hidden="true"><span
            class="river-orbit"
          ></span><span class="river-art-tile"><AppIcon
              @kind="heart"
            /></span><span class="river-art-dot"></span></div>
      </header>
      <nav class="river-tabs" aria-label="功能导航">{{#each
          this.data.tabs key="id"
          as |tab|
        }}<button
            type="button"
            class={{if (eq tab.id this.data.view) "is-active"}}
            aria-current={{if (eq tab.id this.data.view) "page"}}
            disabled={{this.busy}}
            {{on "click" (fn this.tab tab.id)}}
          >{{tab.label}}</button>{{/each}}</nav>
      {{#if this.data.readonly_note}}<p class="river-note" role="status">{{this.data.readonly_note}}</p>{{/if}}
      {{#if this.data.subnav}}<nav class="river-subnav" aria-label="管理分类">{{#each this.data.subnav as |entry|}}<button type="button" class={{if entry.active "is-active"}} {{on "click" (fn this.navigate entry.query)}}>{{entry.label}}</button>{{/each}}</nav>{{/if}}
      {{#if this.data.back}}<button class="btn river-back" type="button" {{on "click" (fn this.navigate this.data.back)}}>返回列表</button>{{/if}}
      {{#if this.data.refresh}}<button class="btn river-back" type="button" disabled={{this.busy}} {{on "click" (fn this.navigate this.data.refresh)}}>刷新任务状态</button>{{/if}}
      {{#if this.error}}<div
          class="river-error"
          role="alert"
        >{{this.error}}</div>{{/if}}
      {{#if this.notice}}<div class="river-notice" role="status"><AppIcon
            @kind="check"
          />{{this.notice}}</div>{{/if}}
      <div class="river-steps" aria-label="认识彼此的三个步骤"><button
          type="button"
          {{on "click" (fn this.tab "me")}}
        ><span>01</span>完善资料</button><span
          class="river-step-line"
        ></span><button
          type="button"
          {{on "click" (fn this.tab "questions")}}
        ><span>02</span>回答问卷</button><span
          class="river-step-line"
        ></span><button
          type="button"
          {{on "click" (fn this.tab "home")}}
        ><span>03</span>主动报名</button></div>
      {{#if this.data.stats}}<div class="river-stats">{{#each
            this.data.stats
            as |stat|
          }}<div><span>{{stat.label}}</span><strong
              >{{#if stat.at}}<time datetime={{stat.at}}>{{formatDateTime stat.at}}</time>{{else}}{{stat.value}}{{/if}}</strong></div>{{/each}}</div>{{/if}}
      {{#if this.data.filters.length}}<form
          class="river-search"
          role="search"
          {{on "submit" this.search}}
        >
          <div class="river-search-main"><span
              class="river-search-mark"
            ><AppIcon @kind="search" /></span><label
            >{{this.primaryFilter.label}}<input
                type="search"
                name={{this.primaryFilter.name}}
                value={{this.primaryFilter.value}}
                placeholder={{this.primaryFilter.placeholder}}
              /></label><button
              class="btn btn-primary"
              type="submit"
              disabled={{this.busy}}
            >筛选<AppIcon @kind="arrow" /></button></div>
          {{#if this.extraFilters.length}}<details
              class="river-filter-extra"
              open={{this.activeFilters}}
            ><summary>更多筛选</summary><div class="river-filter-fields">{{#each
                  this.extraFilters
                  as |field|
                }}<label>{{field.label}}<input
                      type="text"
                      name={{field.name}}
                      value={{field.value}}
                      placeholder={{field.placeholder}}
                    /></label>{{/each}}</div></details>{{/if}}
        </form>{{/if}}

      {{#if this.data.note}}<p class="river-note"><AppIcon @kind="lock" /><span
          >{{this.data.note}}{{#if this.data.note_at}}<time datetime={{this.data.note_at}}>{{formatDateTime this.data.note_at}}</time>{{/if}}</span></p>{{/if}}

      <div class={{this.workspaceClass}}>
        {{#if this.hasCards}}<section
            class="river-content"
            aria-label={{this.currentTitle}}
          ><div class="river-section-heading"><h2
              >{{this.currentTitle}}</h2><span>从一次真诚的认识开始</span></div>
            <div class="river-grid">{{#each
                this.data.cards key="id"
                as |card|
              }}<AppCard
                  @card={{card}}
                  @busy={{this.busy}}
                  @navigate={{this.navigate}}
                  @button={{this.button}}
                  @execute={{this.execute}}
                />{{/each}}</div>
          </section>{{/if}}
        {{#if this.hasForms}}<section
            class="river-forms"
            aria-label="填写与操作"
          >{{#each this.data.forms as |form|}}<AppForm
                @form={{form}}
                @execute={{this.execute}}
              />{{/each}}</section>{{/if}}
        {{#if this.showEmpty}}<div class="river-empty"><span
              class="river-empty-icon"
            ><AppIcon @kind="heart" /></span><strong
            >{{this.data.empty_title}}</strong><p
            >{{this.data.empty_text}}</p></div>{{/if}}
      </div>
      {{#if this.data.pagination}}<nav class="river-pagination" aria-label="分页">
        {{#if this.data.previous}}<button class="btn" type="button" disabled={{this.busy}} {{on "click" (fn this.navigate this.data.previous)}}>上一页</button>{{/if}}
        <span>{{this.data.pagination}}</span>
        {{#if this.data.next}}<button class="btn" type="button" disabled={{this.busy}} {{on "click" (fn this.navigate this.data.next)}}>下一页</button>{{/if}}
      </nav>{{/if}}
      {{#if this.data.export_url}}<p class="river-export"><a href={{this.data.export_url}}>下载我的 RSDate 数据</a></p>{{/if}}
    </main>
  </template>
}
