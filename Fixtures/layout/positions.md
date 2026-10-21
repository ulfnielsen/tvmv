# Positions cmark gets wrong ##

Hard\
break *after* a backslash, then two spaces  
and **strong** after them.

Entities &amp; *emphasis* &copy; `code` &#x1F600; **bold**.

Astral 😀*x* 🇩🇰 **y** and CJK 日本 *語* é_z_.

Code spans: `a` `` b`c `` ` d ` ```e```.

***both*** and **_mixed_** and *__nested__* ~~gone~~ ~single~.

Links: [inline](http://a.b "t") [ref][r] [collapsed][] <http://c.d> www.e.com f@g.hi https://j.k/l.

[r]: http://r.s
[collapsed]: http://c.c

Setext with a hard break\
inside
======

Setext two
----------

> quote *q*
>> nested **n**
> back

1. one
2. two
   - inner [ ] not a task
   - [x] done `c`
3) other

- [ ] todo with *em*
  continued line

| A | *B* | C |
|:--|:-:|--:|
| `x` | a \| b | |
| 😀 | **s** |

![alone](img/a.png "title")

Text ![inline](i.png) <span>html</span> here.

<div>
block html
</div>

```rust info
fn main() {}
```

~~~
tilde fence
~~~

    indented code

```
unclosed at the end
