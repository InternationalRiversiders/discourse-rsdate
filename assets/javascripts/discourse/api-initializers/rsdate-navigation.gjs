import { apiInitializer } from "discourse/lib/api";
export default apiInitializer((api) => {
  // The shared Campus Life section owns application links when installed.
  if (api.container.lookup("service:site-settings").alumni_map_enabled) { return; }
  if (!api.container.lookup("service:site-settings").rsdate_enabled) { return; }
  if (!api.getCurrentUser()?.rsdate_member && true) { return; }
  api.addSidebarSection((BaseSection, BaseLink) => {
    return class extends BaseSection {
      get name() { return "rsdate"; }
      get title() { return "RSDate"; }
      get text() { return "RSDate"; }
      get displaySection() { return true; }
      get links() { return [new (class extends BaseLink {
        get name() { return "rsdate"; }
        get route() { return "rsdate"; }
        get text() { return "RSDate"; }
        get title() { return this.text; }
        get prefixType() { return "icon"; }
        get prefixValue() { return "heart"; }
      })()]; }
    };
  });
});
