import Component from "@glimmer/component";
const paths = {
  map: "M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0ZM15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
  book: "M12 5C8 2 4 3 2 4v15c3-2 7-1 10 1 3-2 7-3 10-1V4c-3-1-7-2-10 1Zm0 0v15M5 8l4 1M15 9l4-1M5 12l4 1M15 13l4-1",
  heart:
    "M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z",
  leaf: "M20 3C9 2 2 8 5 16c7 5 16-1 15-13ZM3 21 15 9M8 16v-5m0 5h5",
  food: "M3 12h18a9 9 0 0 1-18 0Zm3 10h12M8 8c-3-3 3-3 0-6m8 6c-3-3 3-3 0-6",
  search: "M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0Zm-2 5 6 6",
  arrow: "M5 12h14m-6-6 6 6-6 6",
  plus: "M12 5v14M5 12h14",
  lock: "M7 10V7a5 5 0 0 1 10 0v3M5 10h14v12H5Zm7 5v3",
  check: "m4 12 5 5L20 6",
  image: "M3 3h18v18H3Zm0 13 5-5 5 5 3-3 5 5M17 7h.01",
};
export default class extends Component {
  get path() {
    return paths[this.args.kind] || paths.book;
  }
  <template>
    <svg
      class="river-icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    ><path d={{this.path}} /></svg>
  </template>
}
