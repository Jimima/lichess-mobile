import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:lichess_mobile/src/binding.dart';
import 'package:lichess_mobile/src/model/engine/uci_protocol.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:logging/logging.dart';
import 'package:stockfish/stockfish.dart';

enum EngineState { initial, loading, idle, computing, error, disposed }

/// An engine that can compute chess positions.
///
/// This is a high-level abstraction over a chess engine process.
///
/// See [StockfishEngine] for a concrete implementation.
abstract class Engine {
  /// The current state of the engine.
  ValueListenable<EngineState> get state;

  /// The name of the engine.
  String get name;

  /// Start the engine with the given [work].
  Stream<EvalResult> start(Work work);

  /// Stop the engine current computation.
  void stop();

  /// A future that completes once the underlying engine process is exited.
  Future<void> get exited;

  /// Whether the engine is disposed.
  ///
  /// This will be `true` once [dispose] is called. Once the engine is disposed, it cannot be
  /// used anymore, and [start] and [stop] methods will throw a [StateError].
  bool get isDisposed;

  /// Dispose the engine. It cannot be used after this method is called.
  ///
  /// Returns the same future as [exited], that completes once the underlying engine process is exited.
  ///
  /// It is safe to call this method multiple times.
  Future<void> dispose();
}

class StockfishEngine implements Engine {
  StockfishEngine() : _protocol = UCIProtocol();

  Stockfish? _stockfish;
  String _name = 'Stockfish';
  StreamSubscription<String>? _stdoutSubscription;

  bool _isDisposed = false;

  final _state = ValueNotifier(EngineState.initial);

  final UCIProtocol _protocol;
  final _log = Logger('StockfishEngine');

  /// A completer that completes once the underlying engine has exited.
  final _exitCompleter = Completer<void>();

  @override
  ValueListenable<EngineState> get state => _state;

  @override
  String get name => _name;

  @override
  Future<void> get exited => _exitCompleter.future;

  @override
  bool get isDisposed => _isDisposed;

  @override
  Stream<EvalResult> start(Work work) {
    if (isDisposed) {
      throw StateError('Engine is disposed');
    }

    _log.info('engine start at ply ${work.ply} and path ${work.path}');
    _protocol.compute(work);

    if (_stockfish == null) {
      try {
        final stockfish = LichessBinding.instance.stockfishFactory();
        _stockfish = stockfish;

        _state.value = EngineState.loading;
        _stdoutSubscription = stockfish.stdout.listen((line) {
          _protocol.received(line);
        });

        stockfish.state.addListener(_stockfishStateListener);

        // Ensure the engine is ready before sending commands
        void onReadyOnce() {
          if (stockfish.state.value == StockfishState.ready) {
            _protocol.connected((String cmd) {
              stockfish.stdin = cmd;
            });
            stockfish.state.removeListener(onReadyOnce);
          }
        }

        stockfish.state.addListener(onReadyOnce);

        _protocol.isComputing.addListener(() {
          if (_protocol.isComputing.value) {
            _state.value = EngineState.computing;
          } else {
            _state.value = EngineState.idle;
          }
        });
        _protocol.engineName.then((name) {
          _name = name;
        });
      } catch (e, s) {
        _log.severe('error loading stockfish', e, s);
        _state.value = EngineState.error;
      }
    }

    return _protocol.evalStream.where((e) => e.$1 == work);
  }

  void _stockfishStateListener() {
    switch (_stockfish?.state.value) {
      case StockfishState.ready:
        _state.value = EngineState.idle;
      case StockfishState.error:
        _state.value = EngineState.error;
      case StockfishState.disposed:
        _log.info('engine disposed');
        _state.value = EngineState.disposed;
        _exitCompleter.complete();
        _stockfish?.state.removeListener(_stockfishStateListener);
        _state.dispose();
      default:
      // do nothing
    }
  }

  @override
  void stop() {
    if (isDisposed) {
      throw StateError('Engine is disposed');
    }
    _protocol.compute(null);
  }

  @override
  Future<void> dispose() {
    if (isDisposed) {
      return exited;
    }
    _log.fine('disposing engine');
    _isDisposed = true;
    _stdoutSubscription?.cancel();
    _protocol.dispose();
    if (_stockfish != null) {
      _stockfish!.dispose();
    } else {
      _exitCompleter.complete();
    }
    return exited;
  }
}

/// A factory to create a [Stockfish].
///
/// This is useful to be able to mock [Stockfish] in tests.
class StockfishFactory {
  const StockfishFactory();

  Stockfish call() => Stockfish();
}
