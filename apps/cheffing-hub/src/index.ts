import { Hono } from "hono";
import { hubPage } from "./page";

type Bindings = { ENVIRONMENT: string };

const app = new Hono<{ Bindings: Bindings }>();

app.get("/", (c) => c.html(hubPage()));
app.get("/version", (c) => c.json({ env: c.env.ENVIRONMENT }));

export default app;
