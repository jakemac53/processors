// Imports
import 'dart:async';
import 'dart:isolate';

// !considering the shutdown system used by the `Processor` class, having a kill signal (like an
// !int or a String) can be mistaken for a function input and will cause errors. enums are unique,
// !even another single-member enum _kill.code from another file will not be equal to the one
// !defined in this file, hence the creation & use of a single-member enum
enum _kill { code }

/// concurrency made easy - setup a separate process to run a given function with
/// 2 way communication so as to send and process multiple inputs
///
class Processor<R, I> {
  // ============
  // === NOTE ===
  // ============
  // 
  // 1. Why is the "kill signal" sent to the isolate "on the inputPort" and then sent back to the
  //    main process again?
  // 
  //  - The order of what happens in the isolate is totally independent of what happens in the
  //    main process. If the kill signal is not "mirrored"  back, you would have to check if the
  //    isolate has returned its data before shutting it down. Considering that the "processed
  //    data" is made available as a single-subscription Stream, this would make for some rather
  //    convoluted code.
  //
  //  - By placing the kill signal on the same "queue" as the rest of the inputs, we essentially
  //    ensure that the "processor" is shutdown only after all inputs are processed as the kill
  //    signal is at the end of the queue and the inputs precede it - the inputs are processed
  //    first and only then is the kill signal mirrored and the isolate shutdown.
  // 
  // 2. Why use a separate "closePort"?
  //
  //  - To be able to mirror the kill signal, ever single input has to be checked against the kill
  //    signal - an if-else clause - this results in at least 2 extra steps for each computation.
  //    as these are run in a separate isolate, their performance impact is assumed negligible
  //    because (a) isolates are for running "computationally heavy operations" - things that
  //    contain hundreds of thousands of individual steps (if a loop have 5 statements and runs
  //    20 times, that's 100 steps). an additional 2 checks won't make any meaningful impact.
  // 
  //  - On the main process however, there are a lot of other steps being run, the whole point of
  //    offloading work onto an isolate is to ensure timely execution of main process steps and
  //    having to run an additional 2 checks on every single output can quickly snowball into a
  //    huge overhead - lets say you have 100 inputs per isolate, that equals 200 excess steps but
  //    then again you might have 10 isolates running in parallel, this means that each individual
  //    isolate will only suffer 200 steps worth lag while scanning inputs but the main process
  //    will have to handle 2000 steps worth lag that's 10x more than any individual isolate.
  // 
  //  - By having a dedicated "close port" we no longer have to scan every input, as the kill
  //    signal is sent on a separate dedicated port. Now we have effectively "pushed out" and
  //    "divided up" the lag. With 10 isolates running in parallel, each suffering 200 steps
  //    of lag, the total lag is still just 200 steps worth time (as everything is simultaneous)
  //    instead of the 2000 step lag on the main process over and above the 200 step lag across
  //    isolates.
  // 
  // 3. The overall picture
  // 
  //  - By "mirroring" the "kill signal" sent on the inputPort & using a separate "closePort",
  //    you can essentially register a shutdown process that will be run automatically on receiving
  //    the kill signal from the closePort without any worries this inherently guarantees that
  //    that all the inputs sent prior have been processed.

  // ==================
  // === Properties ===
  // ==================

  // port to receive "processed outputs" from the isolate
  final _outputPort = ReceivePort();

  // port that plays a vital role in shutdown/forced-shutdown
  final _closePort = ReceivePort();

  // port to send inputs for the isolate to process
  late final SendPort _inputPort;

  // the isolate in question
  late final Isolate _isolate;

  // a streamController, we use this to enable type checks/enforcement over isolate outputs
  final _streamControl = StreamController<R>();

  // a reference to the function being run in the isolate
  // !this is kept for 2 reasons:
  // !    1. to keep a reference to the function in case its required
  // !    2. to enforce generic type R & I (returnType, InputType)
  //
  /// the function being run in the isolate
  ///
  late final FutureOr<R> Function(I input) function;

  /// a [Stream] containing processed outputs
  ///
  Stream<R> get outputStream => _streamControl.stream;

  // ==============================
  // === Constructors & Methods ===
  // ==============================

  /// setup a Processor that will run the provided function
  ///
  /// ### Args
  /// - function: `R Function(I)`, a function that takes exactly one input
  ///
  /// ### Returns
  /// - `Processor`
  ///
  /// ### Errors
  /// - None
  ///
  /// ### Notes
  /// - you must run [Processor.start] to actually get the underlying isolate up and running,
  /// this just sets up necessary pre-requisites
  ///
  Processor(this.function);

  /// startup the Processor (creates the underlying isolate)
  ///
  /// ### Args
  /// - None
  ///
  /// ### Returns
  /// - None
  ///
  /// ### Errors
  /// - None
  ///
  /// ### Notes
  /// - always `await` this method call, else you'll run into errors due to
  /// uninitialized variables
  ///
  Future<void> start() async {
    // !a throw-away port to obtain an inputPort
    var metaPort = ReceivePort();

    // startup the isolate
    var setupList = [
      function,
      _outputPort.sendPort,
      metaPort.sendPort,
      _closePort.sendPort
    ];
    _isolate = await Isolate.spawn(_functionRunner, setupList);

    // obtain a port to send inputs to the isolate
    // !this shuts down metaPort
    _inputPort = await metaPort.first;

    // redirect all outputs to the stream
    _outputPort.listen((output) => _streamControl.add(output as R));

    // setup shutdown process listener
    // !see NOTE at the top of this class (point 3)
    _closePort.listen((signal) {
      if (signal == _kill.code) {
        _outputPort.close();
        _streamControl.close();
        _isolate.kill();
        _closePort.close();
      }
    });
  }

  /// send an input to be processed
  ///
  /// ### Args
  /// - input: `I`, an input to be sent to the function being run within the `Processor`
  ///
  /// ### Returns
  /// - None
  ///
  /// ### Errors
  /// - None
  ///
  void send(I input) {
    _inputPort.send(input);
  }

  /// send all elements of the provided iterable to be processed
  ///
  /// ### Args
  /// - inputIter: `Iterable<I>`, an iterable of inputs to be sent to the function
  /// being run within this `Processor`
  ///
  /// ### Returns
  /// - None
  ///
  /// ### Errors
  /// - None
  ///
  void sendAll(Iterable<I> inputIter) {
    for (var input in inputIter) {
      send(input);
    }
  }

  /// shutdown the `Processor` after currently supplied inputs are processed
  ///
  /// ### Args
  /// - None
  ///
  /// ### Returns
  /// - None
  ///
  /// ### Errors
  /// - None
  ///
  /// ### Notes
  /// - will shutdown only after all current inputs have been processed, new
  /// inputs will be ignored
  ///
  void shutdown() {
    _inputPort.send(_kill.code);
  }

  /// shutdown `Processor` immediately regardless of supplied inputs
  ///
  /// ### Args
  /// - None
  ///
  /// ### Returns
  /// - None
  ///
  /// ### Errors
  /// - None
  ///
  void forceShutdown() {
    // !see NOTE at the top of this class (point 3)
    _outputPort.close();
    _streamControl.close();
    _isolate.kill();
    _closePort.close();
  }

  // =====================================
  // === Essential Background Function ===
  // =====================================

  /// the function that is run within the isolate, handles the comms. setup
  ///
  /// `setupList` must contain exactly 3 elements in the following order:
  ///   - the function to be run
  ///   - outputPort (to send outputs to main)
  ///   - metaPort (to share inputPort)
  ///   - closPort (to mirror shutdown signal)
  ///
  static void _functionRunner(List setupList) async {
    // get the function to be run, comms. ports
    var function = setupList[0];
    var outputPort = setupList[1] as SendPort;
    var metaPort = setupList[2] as SendPort;
    var closPort = setupList[3] as SendPort;

    // send a port to main so as to receive inputs
    var inputPort = ReceivePort();
    metaPort.send(inputPort.sendPort);

    // start a micro-task queue
    inputPort.listen((input) {
      // if the shutdown signal is given, do the necessary and mirror signal back to main,
      // else process input and send output to main
      // !consider looking at NOTE at the top of this class (point 2)
      if (input == _kill.code) {
        closPort.send(_kill.code);
        inputPort.close();
      } else {
        var output = function(input);
        if (output is Future) {
          output.then(outputPort.send);
        } else {
          outputPort.send(output);
        }
      }
    });
  }
}