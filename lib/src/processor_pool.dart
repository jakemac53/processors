import 'dart:async';
import 'processor.dart';

/// distributed concurrency made easy - run a given function across multiple processes, distribute
/// inputs evenly across all processed
///
class ProcessorPool<R, I> {
  // ==================
  // === Properties ===
  // ==================

  // collection of underlying `Processor`s
  final _pool = <Processor<R, I>>[];

  // indicates which the index of the `Processor` to which the next input will be sent
  var _currentProcessorIndex = 0;

  /// the function being run
  ///
  late R Function(I input) function;

  // a streamController, we use this to enable type checks/enforcement over isolate outputs
  // and also the pipe outputs from all processes into a common output point
  final _streamController = StreamController<R>();

  /// a [Stream] containing processed outputs
  ///
  Stream<R> get outputStream => _streamController.stream;

  /// number of processes on which the given function is being run
  ///
  int get workerCount => _pool.length;

  // ==============================
  // === Constructors & Methods ===
  // ==============================

  /// setup a ProcessorPool that will run the provided function
  ///
  /// ### Args
  /// - function: `R Function(I)`, a function that takes exactly one input
  /// - processorCount: `int`, number of processes across which the function provided should be run
  ///
  /// ### Returns
  /// - `ProcessorPool`
  ///
  /// ### Errors
  /// - None
  ///
  /// ### Notes
  /// - you must run [ProcessorPool.start] to actually get the underlying [Processor]'s up and
  /// running, this just sets up necessary pre-requisites
  ///
  ProcessorPool(this.function, [int processorCount = 8]) {
    for (var i = 0; i < processorCount; i++) {
      // create a Processors
      var processor = Processor(function);
      _pool.add(processor);

      // redirect its output to the common outputStream
      processor.outputStream.listen((output) {
        _streamController.add(output);
      });
    }
  }

  /// startup the ProcessorPool (creates the underlying [Processor]'s)
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
    for (var processor in _pool) {
      await processor.start();
    }
  }

  /// send an input to be processed
  ///
  /// ### Args
  /// - input: `I`, an input to be sent to the function being run within the `ProcessorPool`
  ///
  /// ### Returns
  /// - None
  ///
  /// ### Errors
  /// - None
  ///
  void send(I input) {
    // send input to Processor at _currentProcessorIndex
    _pool[_currentProcessorIndex].send(input);

    // increment _currentProcessorIndex
    _currentProcessorIndex += 1;
    _currentProcessorIndex %= _pool.length;
  }

  /// send all elements of the provided iterable to be processed
  ///
  /// ### Args
  /// - inputIter: `Iterable<I>`, an iterable of inputs to be sent to the function
  /// being run within this `ProcessorPool`
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

  /// shutdown the `ProcessorPool` after currently supplied inputs are processed
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
    for (var processor in _pool) {
      processor.shutdown();
    }
  }

  /// shutdown `ProcessorPool` immediately regardless of supplied inputs
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
    for (var processor in _pool) {
      processor.forceShutdown();
    }
  }
}
