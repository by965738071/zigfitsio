/** Pure card-parser and Header unit tests (no native library needed). */
import { describe, expect, test } from "./_harness/index.js";
import { Header, parseCard, parseCards, parseValueComment } from "../src/header.js";
import { FitsTypeError, KeywordNotFound } from "../src/errors.js";

const pad80 = (s: string): string => s.padEnd(80);

describe("parseValueComment", () => {
  test("string value with '' escapes and comment", () => {
    expect(parseValueComment("'it''s a test'   / a comment")).toEqual(["it's a test", "a comment"]);
  });

  test("logical T/F", () => {
    expect(parseValueComment("                   T / flag")).toEqual([true, "flag"]);
    expect(parseValueComment("                   F")).toEqual([false, ""]);
  });

  test("integers stay exact: number when double-safe, bigint otherwise", () => {
    expect(parseValueComment("                  42")).toEqual([42, ""]);
    expect(parseValueComment("               32768")).toEqual([32768, ""]);
    // 2^63 is exact as a double → number (unsigned-convention detection relies on this).
    expect(parseValueComment(" 9223372036854775808")).toEqual([9223372036854775808, ""]);
    // 2^53+1 is NOT exact as a double → bigint.
    expect(parseValueComment("    9007199254740993")).toEqual([9007199254740993n, ""]);
  });

  test("floats incl. FORTRAN D exponent", () => {
    expect(parseValueComment("             1.5E2 / x")).toEqual([150.0, "x"]);
    expect(parseValueComment("             1.5D2")).toEqual([150.0, ""]);
    expect(parseValueComment("             -0.25")).toEqual([-0.25, ""]);
  });

  test("undefined value and comment-only", () => {
    expect(parseValueComment("        ")).toEqual([null, ""]);
    expect(parseValueComment("   / only a comment")).toEqual([null, "only a comment"]);
  });

  test("unparseable token stays a string", () => {
    expect(parseValueComment("   1.2.3 / weird")).toEqual(["1.2.3", "weird"]);
  });
});

describe("parseCard", () => {
  test("END returns null", () => {
    expect(parseCard(pad80("END"))).toBeNull();
  });

  test("value card", () => {
    const c = parseCard(pad80("OBSERVER= 'Hubble  '           / who"));
    expect(c).toEqual({ keyword: "OBSERVER", value: "Hubble", comment: "who", commentary: false });
  });

  test("COMMENT and HISTORY are commentary", () => {
    expect(parseCard(pad80("COMMENT free text here"))).toEqual({
      keyword: "COMMENT",
      value: "free text here",
      comment: "",
      commentary: true,
    });
    expect(parseCard(pad80("HISTORY step one"))?.commentary).toBe(true);
  });

  test("HIERARCH spaced keyword", () => {
    const c = parseCard(pad80("HIERARCH ESO DET CHIP = 42 / chip id"));
    expect(c).toEqual({ keyword: "ESO DET CHIP", value: 42, comment: "chip id", commentary: false });
  });
});

describe("parseCards CONTINUE folding", () => {
  test("long string folds across CONTINUE cards, comment from last fragment", () => {
    const cards = parseCards([
      pad80("LONGSTR = 'part one &'"),
      pad80("CONTINUE  'part two &'"),
      pad80("CONTINUE  'part three' / done"),
      pad80("END"),
    ]);
    expect(cards).toHaveLength(1);
    // The space before each `&` sentinel is part of the fragment (matches Python).
    expect(cards[0].value).toBe("part one part two part three");
    expect(cards[0].comment).toBe("done");
  });

  test("a lone &-terminated value with no CONTINUE keeps the & literally", () => {
    const cards = parseCards([pad80("KEY     = 'ends with &'"), pad80("END")]);
    expect(cards[0].value).toBe("ends with &");
  });

  test("a '' escape pair split across the CONTINUE boundary folds on raw text (astropy split)", () => {
    // astropy splits the ESCAPED representation and can cut a '' pair in half at a card
    // boundary; unescaping each card independently misreads the split ' as a closing quote.
    const value = "abc'def&".repeat(12) + "END"; // 99 chars, quotes and ampersands throughout
    const escaped = value.replace(/'/g, "''");
    const cut = 67; // cuts the 8th block's '' pair after its first '
    expect(escaped[cut - 1]).toBe("'");
    expect(escaped[cut]).toBe("'");
    const cards = parseCards([
      pad80("LSTR    = '" + escaped.slice(0, cut) + "&'"),
      pad80("CONTINUE  '" + escaped.slice(cut) + "'"),
      pad80("END"),
    ]);
    expect(cards).toHaveLength(1);
    expect(cards[0].value).toBe(value);
  });

  test("HIERARCH long string folds across CONTINUE (no leaked CONTINUE card)", () => {
    const cards = parseCards([
      pad80("HIERARCH ESO LONG STR = 'part one is here &'"),
      pad80("CONTINUE  'part two here.'"),
      pad80("END"),
    ]);
    expect(cards).toHaveLength(1);
    expect(cards[0].keyword).toBe("ESO LONG STR");
    expect(cards[0].value).toBe("part one is here part two here.");
  });

  test("HIERARCH '' pair split across the CONTINUE boundary folds exactly", () => {
    const value = "abc'def&".repeat(12) + "END";
    const escaped = value.replace(/'/g, "''");
    const cut = 49; // 6th block's '' pair; keeps the base card ≤ 80 with the HIERARCH prefix
    expect(escaped[cut - 1]).toBe("'");
    expect(escaped[cut]).toBe("'");
    const cards = parseCards([
      pad80("HIERARCH ESO LSTR = '" + escaped.slice(0, cut) + "&'"),
      pad80("CONTINUE  '" + escaped.slice(cut) + "'"),
      pad80("END"),
    ]);
    expect(cards).toHaveLength(1);
    expect(cards[0].keyword).toBe("ESO LSTR");
    expect(cards[0].value).toBe(value);
  });
});

describe("Header", () => {
  test("Map-like access is ordered and case-insensitive", () => {
    const h = new Header();
    h.set("Alpha", 1);
    h.set("BETA", "two", "second");
    expect(h.has("alpha")).toBe(true);
    expect(h.get("ALPHA")).toBe(1);
    expect(h.get("beta")).toBe("two");
    expect(h.commentOf("Beta")).toBe("second");
    expect(h.keys()).toEqual(["ALPHA", "BETA"]);
    expect(h.length).toBe(2);
    expect([...h]).toEqual([
      ["ALPHA", 1],
      ["BETA", "two"],
    ]);
    h.set("alpha", 5); // updates in place, keeps position
    expect(h.get("ALPHA")).toBe(5);
    expect(h.keys()).toEqual(["ALPHA", "BETA"]);
  });

  test("get with default; value() throws KeywordNotFound", () => {
    const h = new Header();
    expect(h.get("NOPE")).toBeUndefined();
    expect(h.get("NOPE", 7)).toBe(7);
    let caught: unknown = null;
    try {
      h.value("NOPE");
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(KeywordNotFound);
  });

  test("delete removes; deleting a missing key throws", () => {
    const h = new Header();
    h.set("KEY", 1);
    h.delete("key");
    expect(h.has("KEY")).toBe(false);
    let caught: unknown = null;
    try {
      h.delete("KEY");
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(KeywordNotFound);
  });

  test("comments and history collect commentary cards", () => {
    const h = Header.fromCards(
      parseCards([pad80("COMMENT one"), pad80("HISTORY step"), pad80("COMMENT two"), pad80("END")]),
    );
    expect(h.comments).toEqual(["one", "two"]);
    expect(h.history).toEqual(["step"]);
    expect(h.length).toBe(0); // commentary is not a keyword record
  });

  test("persist-first: a throwing persist hook leaves the header unchanged", () => {
    const h = new Header();
    h.set("SAFE", 1);
    h._persist = () => {
      throw new Error("rejected");
    };
    expect(() => h.set("BAD", 2)).toThrow("rejected");
    expect(h.has("BAD")).toBe(false);
    expect(h.get("SAFE")).toBe(1);
  });
});

describe("commentary cards (BUGHUNT #6)", () => {
  test("set accumulates COMMENT/HISTORY instead of overwriting", () => {
    const h = new Header();
    h.set("COMMENT", "first");
    h.set("COMMENT", "second");
    h.set("HISTORY", "step1");
    expect(h.comments).toEqual(["first", "second"]);
    expect(h.history).toEqual(["step1"]);
    expect(h.keys().includes("COMMENT")).toBe(false); // commentary is not a keyword record
    expect(h.length).toBe(0);
    expect(h.has("COMMENT")).toBe(true);
  });

  test("addComment/addHistory append", () => {
    const h = new Header();
    h.addComment("a");
    h.addHistory("b");
    expect(h.comments).toEqual(["a"]);
    expect(h.history).toEqual(["b"]);
  });

  test("long commentary text wraps into ≤72-char cards", () => {
    const h = new Header();
    const long = "x".repeat(100);
    h.set("COMMENT", long);
    expect(h.comments).toEqual([long.slice(0, 72), long.slice(72)]);
    expect(h.comments.every((c) => c.length <= 72)).toBe(true);
  });

  test("commentary() view: index, setAt, removeAt, append", () => {
    const h = new Header();
    h.addComment("one");
    h.addComment("two");
    const v = h.commentary("COMMENT");
    expect(v.length).toBe(2);
    expect(v.at(0)).toBe("one");
    expect(v.at(-1)).toBe("two");
    expect(v.toArray()).toEqual(["one", "two"]);
    expect([...v]).toEqual(["one", "two"]);
    v.setAt(0, "ONE");
    expect(h.comments).toEqual(["ONE", "two"]);
    v.removeAt(0);
    expect(h.comments).toEqual(["two"]);
    v.append("three");
    expect(h.comments).toEqual(["two", "three"]);
  });

  test("array assignment replaces all; delete removes all", () => {
    const h = new Header();
    h.addComment("old");
    h.set("COMMENT", ["p", "q", "r"]);
    expect(h.comments).toEqual(["p", "q", "r"]);
    h.delete("COMMENT");
    expect(h.comments).toEqual([]);
    expect(h.has("COMMENT")).toBe(false);
  });

  test("commentary set routes raw text to the persist hook, not a valued-key write", () => {
    const h = new Header();
    const calls: Array<[string, unknown]> = [];
    h._persist = (key, value) => {
      calls.push([key, value]);
    };
    h.set("COMMENT", "hello");
    expect(calls).toEqual([["COMMENT", "hello"]]); // scalar chunk flows through as commentary text
  });

  test("array value on a valued keyword throws instead of stamping a malformed card", () => {
    const h = new Header();
    expect(() => h.set("BITPIX", [1, 2] as unknown as number)).toThrow(FitsTypeError);
    expect(h.has("BITPIX")).toBe(false);
  });
});
