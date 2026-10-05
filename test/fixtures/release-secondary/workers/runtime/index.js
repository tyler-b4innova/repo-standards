export class Runtime {
  constructor(ctx) { this.ctx = ctx; }
  fetch() { return new Response("fixture"); }
}
export default { fetch() { return new Response("fixture"); } };
