# termichatter-nvim

> Asynchronous structured-data-flow atop coop.nvim, with a side of logging.

# features

- optimize for low cost to send messages
- ability to control individual modules alike `debug` npm module offers
  - ability to adjust log level of each module as well
- making a messages generates a very high resolution timestamp as soon as possible
- multiple consumer implementations. the protocol is based on the contract.
- basic receiver: an async receive loop
  - uses a `driver` to get scheduled
    - `interval` driver uses a fixed scheduling interval
    - `rescheduler` driver fires a new run at the beginning or end of each iteration

# architecture

a series of `pipeline` handlers which messages are passed through. these pipelines are backed by either synchronous passing of data to the next pipeline in the chain, or if there is a `queues` at that next element, must pass the data into the mpsc at queues, for it to be picked up asynchronously. as messages go through, they have a `pipeStep` index which is increased as it iterates. this is used to propogate the message forward. `pipeline` elements may be strings, in which case, lookup the string on the module and run that. if not present, advance to the next handler. if a `queue` is a function, invoke the function (with the message as self) to get a mpsc to pass to, or if empty, assume synchronous processing and move on immediately. if a `queue` is a string, lookup on the self and if truthy assume it is a mpsc to send to.

| variable | value    | special handling                                                 |
| -------- | -------- | ---------------------------------------------------------------- |
| pipeline | function | runs, advanced `pipeStep`, then typically calls `log` to forward |
| pipeline | string   | lookup the string on self and re-evalate                         |

stages of the pipeline use https://tangled.org/jauntywk.bsky.social/mpsc-completion protocol to signal their work. they emit a `hello` export from the main module of `termichatter` to the mpsc on startup. they emit a `done` when . this is the only way for a handler to know that all messages above it are done. these messages are typically recommended to not be logged.

termichatter emphasizes a recursive context. messages might inherit from a logger which inherits from a module which inherits from another module which inherits from the main termichatter-nvim module. all elements of the context can be built on or redefined, at the appropriate level. this includes changing the packet flow for a message by altering it's `pipeline` or `queues`. it is recommended splice only from the current step downwards, to leave the previous steps and pipeStep intact. each handler has discretion on what to do!

it is very important that functions attempt to use the `self` to invoke & refer to other components, to take advantage of this multi-modularity!

## module

a variety of key data structures and objects are provided on the top level module:

| : field :            | : description :                                                                                            |
| -------------------- | ---------------------------------------------------------------------------------------------------------- |
| `pipeline`           | list of handlers that is executed through in order (handler may route message elsewhere though             |
| `queues`             | corresponding list of mpsc queues that messages traverse                                                   |
| `ingester`           | function which decorates messages at log time                                                              |
| `log`                | accepts a raw strcutured log message, running in pipeline                                                  |
| `logger`             | factory function for making a logger                                                                       |
| `baseLogger`         | the default logger factory for `logger`. relies on a module to do most of it's work                        |
| `completion.hello`   | message sent when connecting to a mpsc                                                                     |
| `completion.done`    | messages send when done transmitting to a mpsc                                                             |
| `addProcessor`       | adds a new step to a pipeline, adding the processor at the specified position & making a new queue mpsc    |
| `makePipeline`       | makes a new module, with it's own `pipeline`/`queues` pair, & copying all other fields onto the new module |
| `timestamper`        | function to mint a timestamp                                                                               |
| `driver`             | the driver for this module                                                                                 |
| `drivers.interval`   | an interval driver                                                                                         |
| `driver.rescheduler` | a re-occuring re-scheduler driver. optional backoff when it is quiet to reduce usage.                      |

`termichatter` exposes a main module with all these fields. note however, new modules / universes can be spawned via `makePipeline`.

## pipeline

A default pipeline is:

| step | pipeline        |                                  | description | queue |
| ---- | --------------- | -------------------------------- | ----------- | ----- |
| 1    | `timestamper`   | runs timestmaper, whatever it is |
| 2    | `ingester`      | empty by default, thus skipped   |
| 3    | `cloudevents`   |                                  |
| 4    | `module_filter` |                                  |

## structured events / messages

termichatter allows for arbitrary messages to be passed through. it's recommended messages remain structured data. the following fields are considered conventional & should be used if it makes sense.

the broad recommendation is to leverage otel semantic convention wherever possible!

| field             | description                                                       |
| ----------------- | ----------------------------------------------------------------- |
| `time`            | timestamp at ingestion                                            |
| `id`              | a unique uid                                                      |
| `source`          | a url or colon separated uri describing the origin of the message |
| `type`            | application distinct event type, using reverse domain notation    |
| `datacontenttype` | mime type if appropriate                                          |
| `timestamp`       | timestamp at ingestion                                            |
| `priority`        | a string identifying the priority                                 |

## loggers

a logger is a function itself, that can log messages. it also _ought_ expose functions for `error` `log` `info` `warn` `debug` `trace` messages (in descending priority), that set the priority. termichatter is a general mpsc queue usable for many things, but one of it's primary goals is to make for easy structured logging: loggers are an example producer that makes that easy.

loggers are a typical start of the pipeline, a common often the only tool to adds messages. loggers should be a function,

the `baseLogger` is a simple logger factory, that tries to delegate as much work as it can to it's module.

### baseLogger factory parameters

baseLogger should capture all fields provided to it on the logger function it creates. these override the inherited module it points to.

the function produced by baseLogger should:

- run `timestamper` on message if present
- run `ingester` on message if present

Loggers use the module exports to do their work.

Loggers are usually structured, with a module, with a name. Termichatter itself has a termichatter module, and submodules.

## queue

typically backed by a coop.nvim mpsc, these allow for async gathering of messages

there is a default message queue, but creating special queues is also ok! loggers need to be pointed at the different queue.

## processor

processors consume messages off one queue and forward them to another. typically they will write themselves into .defaultQueue and

| : processor :         | : description :                         |
| --------------------- | --------------------------------------- |
| `ModuleFilter`        | npm `debug` style filter system         |
| `CloudEventsEnricher` | stamps cloudevents fields onto object : |

## outputter

outputters consume messages off one or more mpsc, and do something with them

outputters by default will try to read from `.defaultOutputQueue` and if that is not present (it typically isn't) they read from .defaultQueue

| outputter | desc                     |
| --------- | ------------------------ |
| `buffer`  | appends to buffer        |
| `fan-out` | runs multiple outputters |
| `file`    | appends to a file        |

| parameter            | description                                                                                   |
| -------------------- | --------------------------------------------------------------------------------------------- |
| `buffer.n`           | buffer number to write to                                                                     |
| `fan-out.outputters` | list of outputters to write to                                                                |
| `file.filename`      | file name to write to. path component moved to `dir` if provided                              |
| `file.dir`           | directory to write to, defaults to cwd, set if filename provided as relative or absolute path |

## `log`

log is a function that does most of the work of sending messages through the pipeline. looks for a `pipeStep` to start from, or sets to 0 and starts. fires the handler.

# to research

- what would we want to borrow from pino? what are the core architectural facets defining pino?
