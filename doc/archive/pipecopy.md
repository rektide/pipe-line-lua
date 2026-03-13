# pipecopy implementation

create a new implementations/ based on overlaying the existing pipeline with an enriched sparse `run` executor that sends input elements into a `line` , and collects a `output`. this is a novel clean slate implementation, with new api and new user ergonomics, hoping to improve the handling and understanding of termichatter.

if an abstract hypothetical (pipe) `line` has these `pipe` s:

1. extract
2. transform
3. load

and these handlers are in the registry,

we can iterate through a structure that is just the pipe names, ["extract", "transform", "load"] (for an abstract but familiar example)

also key to this design, we retain a key-valued registry of processor "pipes"

# glossary

| term       | description                                       |
| ---------- | ------------------------------------------------- |
| `line`     | a series of pipes that runs a `run`               |
| `pipe`     | a processing component, a handler, in a pipeline  |
| `run`      | an execution of one input to & through a pipeline |
| `registry` | a repository of known pipe types                  |

# line

> The pipeline, a line of pipes.

a collection of pipe elements. optional extra context.

| field       | description                                                           |
| ----------- | --------------------------------------------------------------------- |
| `type=line` | type identifier                                                       |
| `pipe`      | iterable or array of resolve or unresolved pipelines                  |
| `rev`       | counter for revision of the line. goes up every time the line changes |
| `mpsc`      | sparse array of mpsc for pipe components                              |
| `output`    | mpsc-like output that elements can be sent to                         |
| `clone()`   | copies the pipe, with new mpsc and output                             |
| `splice()`  | modify elements in the pipeline, rev                                  |

**Notes:**

- `splice(self, startIndex, deleteCount, ...new)` function on run to modify the `line`, recommended for all pipeline modification/construction. increments `rev`
- `run` helper to create a Run::new

# run

> A self-running "cursor" that walks/visits a pipeline

this is Cursor like entity that walks the line.

- a Run inherits from the `line` of which it was instantiated, it has a \_\_metatable that enriches / derives from a line.
- immediately after, all options passed to the constructor are written to self
- unless `noStart` is specified, begins run execution by running first pipe
- walks through the line, running each pipe in `pipe` one after another.
- to run through a pipe, we look at `current` to get the current pipe. and we call it as a function, using the `run` as self

### `run` life-cycle pipes

review of what a run will typically look like. behavior of our pipeline used to have significant logic in the pipeline itself. here we seek to decompose this, and make pipes for each behavior of the line / run.

pipes typically run these :

1. optional `materializeLine` pipe, shallow copies `pipe` off line so it can be changed. adds a `splice` method to the `pipe` for modificaiton.
2. `init` pipe optionally walk the pipe ahead of time and to run any `init` 's that are on each pipe.
3. `mode` looks up the `current` pipe's `mode` tag/tags and runs all those pipes when it executes. the mode pipe is looked up in the registry and ran. this allows
4. `async` insures the `line`

But the individual objects of the queue still mostly need to pass through to the parent version, the pipeline's copy. but any updates will end up on the Cursor's copy of the pipeline stage. materilzize a `stage names` array at resolution time too.

we want to allow handlers to be able to rewrite the pipeline as they go. add a splice() call that allows for pipeline rebuild, with JS parameters (numberOfElementsToDelete, index, ...elementsToAdd). also update the cursor. resolve the name of any handlers from the registry here.

| field      | description                                                                                 |
| ---------- | ------------------------------------------------------------------------------------------- |
| `type=run` | type identifier                                                                             |
| `line`     | reference to the underlying pipeline, powers it's \_\_metatable, but allows referencing the |
| `pipe`     | own copy of the pipeline                                                                    |
| `pos`      | position in the pipeline                                                                    |
| `posName`  | materialized name of the current position, for help                                         |
| `current`  | link to `pipe` at current `pos`                                                             |

**Notes**

- pos stores numbers for future pos, but if passed a string, walks pipe to find that and sets the index
- optimization: we don't actually need to copy the `pipe` ahead of time, only need to do so if we splice
- overrides `splice` to also modify `pos` with a corresponding edit/change, to keep position preserved

each execution spawns a new Cursor, that for each stage, creates it's own copy. the stage should look like @implementations/sync-or-mpsc-core . that's probably an ok implementation general concept to use. we want to simplify the API surface here considerably, rend it down to more generic pieces. make pipeline becomes a makeCursor, that copies and walks it's own copy of the stack. it needs an iterator too, the cursor. the cursor . i think the trick is that we want weak overlays. we want to be able to have a stage, that lacks a

# pipe

| field  | description                                                                                 |
| ------ | ------------------------------------------------------------------------------------------- |
| `mode` | execution form. "mpsc" means to execute async through a mpsc; pipeline creates mpsc as runs |

# assorted thoughts

> Not entirely well formed or well structured ideas that maybe should be encorporated

- data 'push' through pipeline, async items immediately flow to next item. we need an api to allow a pipe to push more than one element to next, be the next sync or async. we can maybe say sync processors
- `mpsc-completion` standard protocoal (~/src/mpsc-completion) when doing async, so we know when all elements are done
- `state` is a string for current state in a state machine that goes: `new` -> `open` -> `closing` -> closed, based off mpsc completion protocol.
- `type` on all things that is a string of what they are in the registry
- i want to find a better name than `consumers` for the async pipeline driving.
- CRITICAL INSIGHT: `run` is MAYBE an anti-pattern and should be un-designed from this system. making a separate object for every element flowing through the system is NOT GREAT? we used to implicitly flow through the system without needing an object to navigate through the line; we just called the next element, or put elements into the queue.
  - sync processors can just invoke the next pipe multiple times
  - async just means pushing data into the mpsc again and again
- `splice`'ing the line is seems dubious as heck once data is flowing through, hence the materializeLine. it would be nice to have a more full-dynamic option that doesn't cause jank
- the `rev` is an affordance to at least know something has changed
- i liked and tried maybe successfully maybe not to iterate on implementations/sync-or-mpsc/s `mode =`; i don't really know how good this is.

# registry

> colletion of known pipe types

registry serves to offer the known pipe types to the system. a line inherits from a registry.

there is a default registry. sub-registries are encouraged to inherit from the default!

# utilities

- some kinds of "inheritance" helpers that can be called things defining their \_\_metatable implementation to use a parent" object or objects. easy tools to do member lookups on "parents". this ought be used to create an inheritance chains. we also want to record metadata that capture what inhertiances there are, that writes a "parents" array.
- walk inherticance helper, to walk a parent tree looking for fields or looking for a predicate function to fire

# misc

- filenaming: NEVER pluralize a name. ALL identifiers are to be singular in form.

# prompts

- we made termichatter and have some sample implementations, described in @README.md. we want a fresh take, described in @doc/discovery/pipecopy.md , pipecopy. please implement
- jj commit. then create a fresh README.md in the implementations/pipecopy/ that could be a stand-alone README as though this implenetation was the entire project. then create a new README for ANOTHER implementation, that, instead of using Run, implements a somewhat structurally similar implementation, but which omits an explicit run object, and which instead just passes elements implicitly through the `line`. then jj commit this alternate implementation's readme.
