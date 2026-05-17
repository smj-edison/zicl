const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;
const strutil = @import("../strutil.zig");

const ta = std.testing.allocator;

test "codepointLength diagnostic" {
    try std.testing.expectEqual(@as(usize, 8), strutil.codepointLength("1abc2de3"));
    try std.testing.expectEqual(@as(usize, 8), strutil.codepointLength("abc2de3f"));
}

test "regexp basic match" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ regexp "hello" "hello world"
    );
    try interp.testExpectScriptResult("0",
        \\ regexp "foo" "hello world"
    );
}

test "regexp -nocase" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ regexp -nocase "HELLO" "hello world"
    );
    try interp.testExpectScriptResult("0",
        \\ regexp "HELLO" "hello world"
    );
}

test "regexp capture variables" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("helloworld",
        \\ regexp {hello(\w+)} "helloworld" match group1
        \\ set match
    );
    try interp.testExpectScriptResult("world",
        \\ regexp {hello(\w+)} "helloworld" match group1
        \\ set group1
    );
}

test "regexp -all" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("2",
        \\ regexp -all "o" "hello world"
    );
    try interp.testExpectScriptResult("3",
        \\ regexp -all "l" "hello world"
    );
}

test "regexp -all with capture variables" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Variables get the values from the last match.
    try interp.testExpectScriptResult("c",
        \\ regexp -all "(.)" "abc" match group1
        \\ set group1
    );
}

test "regexp -inline" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("helloworld world",
        \\ regexp -inline {hello(\w+)} "helloworld"
    );
    try interp.testExpectScriptResult("",
        \\ regexp -inline "foo" "hello world"
    );
}

test "regexp -all -inline" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("o o",
        \\ regexp -all -inline "o" "hello world"
    );
}

test "regexp -indices" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("0 9",
        \\ regexp -indices {hello(\w+)} "helloworld" match group1
        \\ set match
    );
    try interp.testExpectScriptResult("5 9",
        \\ regexp -indices {hello(\w+)} "helloworld" match group1
        \\ set group1
    );
}

test "regexp -inline -indices" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("{0 4}",
        \\ regexp -inline -indices "hello" "hello"
    );
}

test "regexp -start" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("world",
        \\ regexp -start 5 {(\w+)} "helloworld" match
        \\ set match
    );
}

test "regexp basic operation" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ regexp ab*c abbbc
    );
    try interp.testExpectScriptResult("1",
        \\ regexp ab*c ac
    );
    try interp.testExpectScriptResult("0",
        \\ regexp ab*c ab
    );
    try interp.testExpectScriptResult("1",
        \\ regexp -- -gorp abc-gorpxxx
    );
    try interp.testExpectScriptResult("1",
        \\ regexp {^([^ ]*)[ ]*([^ ]*)} "" a
    );
}

test "regexp capture variables basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 abbbbc",
        \\ set foo {}
        \\ list [regexp ab*c abbbbc foo] $foo
    );
    try interp.testExpectScriptResult("1 abbbbc bbbb",
        \\ set foo {}
        \\ set f2 {}
        \\ list [regexp a(b*)c abbbbc foo f2] $foo $f2
    );
    try interp.testExpectScriptResult("1 abbbbc bbbb",
        \\ set foo {}
        \\ set f2 {}
        \\ list [regexp a(b*)(c) abbbbc foo f2] $foo $f2
    );
    try interp.testExpectScriptResult("1 abbbbc bbbb c",
        \\ set foo {}
        \\ set f2 {}
        \\ set f3 {}
        \\ list [regexp a(b*)(c) abbbbc foo f2 f3] $foo $f2 $f3
    );
}

test "regexp capture variables optional groups" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 a a {} {}",
        \\ set foo 2; set f2 2; set f3 2; set f4 2
        \\ list [regexp (a)(b)? xay foo f2 f3 f4] $foo $f2 $f3 $f4
    );
    try interp.testExpectScriptResult("1 ac a {} c",
        \\ set foo 1; set f2 1; set f3 1; set f4 1
        \\ list [regexp (a)(b)?(c) xacy foo f2 f3 f4] $foo $f2 $f3 $f4
    );
}

test "regexp -indices capture variables" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 {0 5}",
        \\ set foo {}
        \\ list [regexp -indices ab*c abbbbc foo] $foo
    );
    try interp.testExpectScriptResult("1 {0 5} {1 4}",
        \\ set foo {}
        \\ set f2 {}
        \\ list [regexp -indices a(b*)c abbbbc foo f2] $foo $f2
    );
    try interp.testExpectScriptResult("1 {0 5} {1 4} {5 5}",
        \\ set foo {}
        \\ set f2 {}
        \\ set f3 {}
        \\ list [regexp -indices a(b*)(c) abbbbc foo f2 f3] $foo $f2 $f3
    );
    try interp.testExpectScriptResult("1 {1 1} {1 1} {-1 -1} {-1 -1}",
        \\ set foo 2; set f2 2; set f3 2; set f4 2
        \\ list [regexp -indices (a)(b)? xay foo f2 f3 f4] $foo $f2 $f3 $f4
    );
    try interp.testExpectScriptResult("1 {1 2} {1 1} {-1 -1} {2 2}",
        \\ set foo 1; set f2 1; set f3 1; set f4 1
        \\ list [regexp -indices (a)(b)?(c) xacy foo f2 f3 f4] $foo $f2 $f3 $f4
    );
}

test "regexp -nocase capture" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 aBbbxYXxxZ Bbb xYXxx",
        \\ set f1 22
        \\ set f2 33
        \\ set f3 44
        \\ list [regexp -nocase {a(b*)([xy]*)z} aBbbxYXxxZ22 f1 f2 f3] $f1 $f2 $f3
    );
}

test "regexp -all with -inline" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("b b b b b b",
        \\ regexp -all -inline b abababbabaaaaaaaaaab
    );
    try interp.testExpectScriptResult("10 20 30 40",
        \\ regexp -all -inline {\d+} "10:20:30:40"
    );
}

test "regexp -all -inline -indices" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("{0 4} {1 3} {2 2} {-1 -1} {5 9} {6 8} {-1 -1} {7 7}",
        \\ regexp -all -inline -indices a(b(c)d|e(f)g)h abcdhaefgh
    );
}

test "regexp -all with capture vars gets last match" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("aefgh efg {} f {}",
        \\ regexp -all a(b(c)d|e(f)g)h abcdhaefgh a b c d e
        \\ list $a $b $c $d $e
    );
}

test "regexp -start edge cases" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 1",
        \\ list [regexp -start -10 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("1 2",
        \\ list [regexp -start 2 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("1 2",
        \\ list [regexp -start 4 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("1 3",
        \\ list [regexp -start 5 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("0",
        \\ regexp -start [string length 1abc2de3] {\d} 1abc2de3 x
    );
    try interp.testExpectScriptResult("0",
        \\ regexp -start 2 {^$} {}
    );
}

test "regexp -inline no matches" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("",
        \\ regexp -inline {\w(\d+)\w} ""
    );
    try interp.testExpectScriptResult("",
        \\ regexp -inline hello goodbye
    );
}

test "regexp -inline with captures" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("b b",
        \\ regexp -inline (b) ababa
    );
    try interp.testExpectScriptResult("e456d 456",
        \\ regexp -inline {\w(\d+)\w} "   hello 23 there456def "
    );
}

test "regexp empty string" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1",
        \\ regexp -- ^ {}
    );
    try interp.testExpectScriptResult("1",
        \\ regexp -start 0 -- ^ {}
    );
    try interp.testExpectScriptResult("0",
        \\ regexp -start 3 -- ^ {123}
    );
    try interp.testExpectScriptResult("1",
        \\ regexp -start 3 -- $ {123}
    );
}

test "regsub basic operation" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 xax111aaa222xaa",
        \\ list [regsub aa+ xaxaaaxaa 111&222 foo] $foo
    );
    try interp.testExpectScriptResult("1 aaa111xaa",
        \\ list [regsub aa+ aaaxaa &111 foo] $foo
    );
    try interp.testExpectScriptResult("1 xax111aaa",
        \\ list [regsub aa+ xaxaaa 111& foo] $foo
    );
    try interp.testExpectScriptResult("1 11aaa2aaa333",
        \\ list [regsub aa+ aaa 11&2&333 foo] $foo
    );
    try interp.testExpectScriptResult("1 xaxaaa2aaa333xaa",
        \\ list [regsub aa+ xaxaaaxaa &2&333 foo] $foo
    );
    try interp.testExpectScriptResult("1 xax1aaa22aaaxaa",
        \\ list [regsub aa+ xaxaaaxaa 1&22& foo] $foo
    );
}

test "regsub capture groups" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 xax1aa22aaxaa",
        \\ list [regsub a(a+) xaxaaaxaa {1\122\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 {xax1\\aa22aaxaa}",
        \\ list [regsub a(a+) xaxaaaxaa {1\\\122\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 {xax1\\122aaxaa}",
        \\ list [regsub a(a+) xaxaaaxaa {1\\122\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 {xax1\\aaaaaxaa}",
        \\ list [regsub a(a+) xaxaaaxaa {1\\&\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 xax1&aaxaa",
        \\ list [regsub a(a+) xaxaaaxaa {1\&\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 xaxaaaaaaaaaaaaaaxaa",
        \\ list [regsub a(a+) xaxaaaxaa {\1\1\1\1&&} foo] $foo
    );
}

test "regsub no match and anchored" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("0 xyz",
        \\ set foo xxx; list [regsub abc xyz 111 foo] $foo
    );
    try interp.testExpectScriptResult("1 {111 xyz}",
        \\ set foo xxx; list [regsub ^ xyz "111 " foo] $foo
    );
    try interp.testExpectScriptResult("1 {abc111 def}",
        \\ set foo xxx; list [regsub -- -foo abc-foodef "111 " foo] $foo
    );
    try interp.testExpectScriptResult("0 {}",
        \\ set foo xxx; list [regsub x "" y foo] $foo
    );
}

test "regsub -nocase" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 xaAAaAAay",
        \\ list [regsub -nocase a(a+) xaAAaAAay & foo] $foo
    );
    try interp.testExpectScriptResult("0 xaAAaAAay",
        \\ set foo 123; list [regsub a(a+) xaAAaAAay & foo] $foo
    );
    try interp.testExpectScriptResult("1 CbDE",
        \\ set foo 123; list [regsub -nocase a CaDE b foo] $foo
    );
    try interp.testExpectScriptResult("1 CbD",
        \\ set foo 123; list [regsub -nocase XYZ CxYzD b foo] $foo
    );
}

test "regsub -all" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("4 a|xxx|b|xx|c|x|d|x|",
        \\ set foo 86; list [regsub -all x+ axxxbxxcxdx |&| foo] $foo
    );
    try interp.testExpectScriptResult("1 a|xxx|bxxcxdx",
        \\ set foo 86; list [regsub x+ axxxbxxcxdx |&| foo] $foo
    );
    try interp.testExpectScriptResult("0 axxxbxxcxdx",
        \\ set foo 86; list [regsub -all bc axxxbxxcxdx |&| foo] $foo
    );
    try interp.testExpectScriptResult("2 {yy yy more}",
        \\ set foo xxx; list [regsub -all node "node node more" yy foo] $foo
    );
    try interp.testExpectScriptResult("1 123xxx",
        \\ set foo xxx; list [regsub -all ^ xxx 123 foo] $foo
    );
}

test "regsub without varName returns value" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("aXaca",
        \\ regsub b abaca X
    );
    try interp.testExpectScriptResult("XbXcX",
        \\ regsub -all a abaca X
    );
    try interp.testExpectScriptResult("a,bcd,c,eabcfde",
        \\ regsub {b([^d]*)d} abcdeabcfde {,&,\1,}
    );
    try interp.testExpectScriptResult("a,bcd,c,ea,bcfd,cf,e",
        \\ regsub -all {b([^d]*)d} abcdeabcfde {,&,\1,}
    );
}

test "regsub -start" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("4 a1b/2c/3d/4e/5",
        \\ set x {}; list [regsub -all -start 2 {\d} a1b2c3d4e5 {/&} x] $x
    );
    try interp.testExpectScriptResult("0 hello",
        \\ set x {}; list [regsub -all -start -25 {z} hello {/&} x] $x
    );
    try interp.testExpectScriptResult("0 hello",
        \\ set x {}; list [regsub -all -start 3 {z} hello {/&} x] $x
    );
    try interp.testExpectScriptResult("1 cbc",
        \\ list [regsub -start 2 -start 0 a abc c x] $x
    );
    try interp.testExpectScriptResult("0 abc",
        \\ list [regsub -start 0 -start 2 a abc c x] $x
    );
}
