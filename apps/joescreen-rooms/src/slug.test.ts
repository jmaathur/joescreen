import { describe, it, expect } from "vitest";
import { isValidSlug, makeSlug, normalizeCustomSlug, deepLink } from "./slug";

describe("isValidSlug", () => {
	it("accepts well-formed slugs", () => {
		expect(isValidSlug("demo")).toBe(true);
		expect(isValidSlug("my-room-7")).toBe(true);
		expect(isValidSlug("abcd")).toBe(true);
	});
	it("rejects too-short / too-long / bad chars / edge dashes", () => {
		expect(isValidSlug("ab")).toBe(false);
		expect(isValidSlug("a".repeat(25))).toBe(false);
		expect(isValidSlug("Has Space")).toBe(false);
		expect(isValidSlug("under_score")).toBe(false);
		expect(isValidSlug("-lead")).toBe(false);
		expect(isValidSlug("trail-")).toBe(false);
	});
});

describe("makeSlug", () => {
	it("is deterministic given the same bytes and uses the unambiguous alphabet", () => {
		const bytes = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
		const a = makeSlug(bytes);
		const b = makeSlug(bytes);
		expect(a).toBe(b);
		expect(a.length).toBe(7);
		expect(a).not.toMatch(/[0o1l]/); // no ambiguous chars
		expect(isValidSlug(a)).toBe(true);
	});
});

describe("normalizeCustomSlug", () => {
	it("lowercases, dashes spaces, strips invalid", () => {
		expect(normalizeCustomSlug("My Cool Room")).toBe("my-cool-room");
		expect(normalizeCustomSlug("  Team!! Sync  ")).toBe("team-sync");
	});
	it("returns null when the result is invalid", () => {
		expect(normalizeCustomSlug("ab")).toBeNull(); // too short after normalize
		expect(normalizeCustomSlug("!!!")).toBeNull(); // nothing left
	});
});

describe("deepLink", () => {
	it("builds joescreen://join with server + room, no identity", () => {
		const link = deepLink({ room: "demo", sfu: "wss://sfu.example.com" });
		expect(link).toContain("joescreen://join?");
		expect(link).toContain("room=demo");
		expect(link).toContain("server=wss");
		expect(link).not.toContain("identity"); // fresh per joiner
	});
});
