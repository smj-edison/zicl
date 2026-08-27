## LLM disclosure

I currently have been using this project as a testbed for what Claude Sonnet 4.5 is capable of. So far it has only generated small methods and helped with refactoring, as I find it has no taste when generating large amounts of code. All code generated is reviewed by me, and I have a decent test suite to check it against.

## Hurried overview
(from https://folk.computer/newsletters/2026-05#experimental-tcl-interpreter-update-zicl)

### Dictionary lookup
Conventional Tcl dictionary lookup is kind of a pain. You have to do [dict get $dictionary foo] for a key, or [dict get $dictionary foo bar] for nested keys. Jimtcl makes this a bit better with "$dictionary(foo)", but that still doesn't allow for nested key lookup. I decided to steal Tcl's namespace design, except that it does dictionary lookup instead. Getting a value looks like "$dictionary::foo", and setting a value is just "set dictionary::foo value". This also allows for nested keys, like "$dictionary::foo::bar". Now you might be wondering, "what about Tcl namespaces then?" Well, I removed them. Functions are now first-class in Zicl, which means to create a "library", you'd just do 
```tcl
set namespace {}
fn namespace::foo {x y} {
  return [+ $x $y]
}
```
Speaking of functions as first-class concepts, that leads us to

### Functions
Tcl is designed by separating the procedure and variable scopes. You can have a procedure called "foo" and a variable called "foo", and they exist side-by-side. This is because the way procedures are looked up is different than variables. I don't particularily like this, so I've decided to take a page from Scheme's book and have everything in a unified space. This means that code such as
```tcl
set foo {fn impl {{x y} { return [+ $x $y] }}}
foo
```
actually looks up "foo" in the local scope, parses it, and evaluates it as a function. This is great, because then you can put functions in dictionaries, and call them directly:
```tcl
set namespace {}
fn namespace::foo {x y} {
  return [+ $x $y]
}
puts "Result: [namespace::foo 5 10]"
```

You can also redeclare them to "import": 
```tcl
set foo $namespace::foo
puts "Result: [foo 5 10]"
```

Now this is great and all, but there's one glaring issue: Jim's OO system is very dependent on namespaces, particularly the fact that namespaces can mutate. With this new design for "namespaces", they're an immutable dictionary, so the OO system wouldn't really work. Or could it? I figured if we're gonna lean all in on immutability, we might as well steal from one of the most famous immutable languages: Haskell. Enter Monads. Monads allow you to do an operation on a dictionary, while preserving the fact that it's a dictionary:
```tcl
set counterObj {value 5}
fn incrCounter {counterObj} {
  set counterObj::value [+ $counterObj::value 1]
  return $counterObj
}
set counterObj [incrCounter $counterObj]
puts $counterObj ;# {value 6}
```
This does work, but it's a lot of boilerplate. In addition, it can't return a value alongside the object. So I've added some sugary machinery that makes it much easier to work with these quasi-monads. Enter methods. Here's the same as above, except with a method: 
```tcl
set counterObj {value 5}
method counterObj::incr {self} {
  set self::value [+ $self::value 1]
}
counterObj::incr
puts $counterObj ;# {value 6 incr {method ...}}
```
This way you get all the goodies of OO, while still being transparent to what's actually stored in the object at any time. This way objects should sync much nicer across threads and computers, since the values are stored directly in the object.

However, there's one big disadvantage: each object lugs around all of its objects. This is a good way to explode the size of all of your objects and grind object transferring to a halt. So what to do? Well, be inspired by Self, of course, and by extension JavaScript and Lua. If you're familiar with JavaScript, I'm talking about prototype lookup, and if you're familiar with Lua, I'm talking about metatables. The beauty of prototype lookup is that you have one core object/table/dictionary that implements all of the object's methods, and then you "link" a new object to those methods. In Zicl, this looks something like
```tcl
set methods {}
method methods::add {self amount} {
  incr self::count $amount
}
set newObject [dict link $methods {count 0}]
newObject::add 1
puts $newObject ;# {count 1 ~parent blake3^W9aTJiCMFQKJXFqkFxyx5am1XFJ16ctLUeQ8auJFbts}
```

You'll notice that there's a "~parent" field. This contains a hash of the linked dictionary. This is very important: it's not a pointer, it's a hash. That means it's content based, and so it's stable across systems. It's also stable when saved to disk. The biggest downside to this is you have to keep the hash's value alive. So how do we keep hash values alive?

### Hashes as first-class concepts
The hard thing about introducing hashes is you need to keep their corresponding value alive. You also don't want hash values to leak if nothing refers to them. LRU caches are right out because you can't guarantee that a value exists, as it might be ejected. So, in Zicl, whenever a string is created, the string is scanned for hashes, and the hash value is ref counted by that string. If another string is created referencing an unresolved hash, it'll look it up in the central table and borrow the value. This also means that when syncing between systems, you could do something like a Git-style sync where only missing hashes are synced to the other computer. Hash values could also be persisted to the hard drive by having a disk-level ref counting system, though that would be a lot trickier to pull off. 

### Scope capture
Now that we've covered linked dictionaries, I can finally explain how function scope capture happens. When you create a function, it captures the immediate scope. That scope may in turn reference a higher up scope. Well, that sounds an awful lot like linked dictionaries, doesn't it? So, scope capture works by getting a hash to the immediate scope, and that immediate scope in turn has parent links going all the way back to the highest lexical scope. So now closures can by synced! In fact, I'm curious what continuation-style programming would by like, where you evaluate the first step of a function, send it to a different computer that does the next step, and so on. Because all variables are captured, it should hopefully transparently move around. 
