import 'dart:async';
import 'package:async/async.dart';
import 'package:collection/collection.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart'
    hide Tuple2;

import 'package:lichess_mobile/src/common/move_feedback.dart';
import 'package:lichess_mobile/src/common/sound_service.dart';
import 'package:lichess_mobile/src/common/models.dart';
import 'package:lichess_mobile/src/common/tree.dart';
import 'package:lichess_mobile/src/common/uci.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_repository.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_service.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_theme.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_preferences.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_session.dart';
import 'package:lichess_mobile/src/model/puzzle/puzzle_difficulty.dart';

part 'puzzle_view_model.g.dart';
part 'puzzle_view_model.freezed.dart';

@riverpod
class PuzzleViewModel extends _$PuzzleViewModel {
  // ignore: avoid-late-keyword
  late Node _gameTree;
  Timer? _firstMoveTimer;
  Timer? _viewSolutionTimer;
  // on streak, we pre-load the next puzzle to avoid a delay when the user
  // completes the current one
  Future<PuzzleContext?>? _nextPuzzleFuture;

  @override
  PuzzleViewModelState build(
    PuzzleContext initialContext, {
    PuzzleStreak? streak,
  }) {
    ref.onDispose(() {
      _firstMoveTimer?.cancel();
      _viewSolutionTimer?.cancel();
    });

    return _loadNewContext(initialContext, streak, null);
  }

  Future<void> playUserMove(Move move) async {
    _addMove(move);

    if (state.mode == PuzzleMode.play) {
      final movesToTest =
          state.nodeList.sublist(state.initialPath.size).map((e) => e.sanMove);

      final isGoodMove = state.puzzle.testSolution(movesToTest);

      if (isGoodMove) {
        state = state.copyWith(
          feedback: PuzzleFeedback.good,
        );

        final isCheckmate = movesToTest.last.san.endsWith('#');
        final nextUci =
            state.puzzle.puzzle.solution.getOrNull(movesToTest.length);
        // checkmate is always a win
        if (isCheckmate) {
          _completePuzzle();
        }
        // another puzzle move: let's continue
        else if (nextUci != null) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          _addMove(Move.fromUci(nextUci)!);
        }
        // no more puzzle move: it's a win
        else {
          _completePuzzle();
        }
      } else {
        state = state.copyWith(
          feedback: PuzzleFeedback.bad,
        );
        _onComplete(PuzzleResult.lose);
        if (streak == null) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          _setPath(state.currentPath.penultimate);
        }
      }
    }
  }

  void userNext() {
    _viewSolutionTimer?.cancel();
    _goToNextNode();
  }

  void userPrevious() {
    _viewSolutionTimer?.cancel();
    _goToPreviousNode();
  }

  void viewSolution() {
    if (state.mode == PuzzleMode.view) return;

    _mergeSolution();

    state = state.copyWith(
      nodeList: IList(_gameTree.nodesOn(state.currentPath)),
    );

    _onComplete(PuzzleResult.lose);

    state = state.copyWith(
      mode: PuzzleMode.view,
    );

    _viewSolutionTimer =
        Timer.periodic(const Duration(milliseconds: 800), (timer) {
      if (state.canGoNext) {
        _goToNextNode();
      } else {
        timer.cancel();
      }
    });
  }

  void skipMove() {
    state = state.copyWith(
      streakHasSkipped: true,
    );
    final moveIndex = state.currentPath.size - state.initialPath.size;
    final solution = state.puzzle.puzzle.solution[moveIndex];
    playUserMove(Move.fromUci(solution)!);
  }

  Future<PuzzleContext?> changeDifficulty(PuzzleDifficulty difficulty) async {
    state = state.copyWith(
      isChangingDifficulty: true,
    );

    await ref
        .read(
          puzzlePreferencesProvider(initialContext.userId).notifier,
        )
        .setDifficulty(difficulty);

    final nextPuzzle = await ref.read(defaultPuzzleServiceProvider).resetBatch(
          userId: initialContext.userId,
          angle: initialContext.theme,
        );

    state = state.copyWith(
      isChangingDifficulty: false,
    );

    return nextPuzzle;
  }

  void continueWithNextPuzzle(PuzzleContext nextContext) {
    state = _loadNewContext(nextContext, streak, state.streakIndex).copyWith(
      streakIndex: state.streakIndex,
      streakHasSkipped: state.streakHasSkipped,
    );
  }

  void sendStreakResult() {
    if (initialContext.userId != null) {
      final repo = ref.read(puzzleRepositoryProvider);
      repo.postStreakRun(state.streakIndex ?? 0);
    }
  }

  PuzzleViewModelState _loadNewContext(
    PuzzleContext context,
    PuzzleStreak? streak,
    int? streakIndex,
  ) {
    final root = Root.fromPgn(context.puzzle.game.pgn);
    _gameTree = root.nodeAt(root.mainlinePath.penultimate) as Node;

    // play first move after 1 second
    _firstMoveTimer = Timer(const Duration(seconds: 1), () {
      _setPath(state.initialPath);
    });

    final initialPath = UciPath.fromId(_gameTree.children.first.id);

    if (streak != null) {
      final nextId = streak.getOrNull((streakIndex ?? 0) + 1);
      _nextPuzzleFuture = nextId != null
          ? Result.release(
              ref
                  .read(puzzleRepositoryProvider)
                  .fetch(streak.get((streakIndex ?? 0) + 1)),
            ).then(
              (puzzle) => PuzzleContext(
                theme: PuzzleTheme.mix,
                puzzle: puzzle,
                userId: initialContext.userId,
              ),
            )
          : Future.value(null);
    }

    return PuzzleViewModelState(
      puzzle: context.puzzle,
      glicko: context.glicko,
      mode: PuzzleMode.play,
      initialPath: initialPath,
      currentPath: UciPath.empty,
      nodeList: IList([ViewNode.fromNode(_gameTree)]),
      pov: _gameTree.nodeAt(initialPath).ply.isEven ? Side.white : Side.black,
      resultSent: false,
      isChangingDifficulty: false,
    );
  }

  void _goToNextNode() {
    if (state.node.children.isEmpty) return;
    _setPath(state.currentPath + state.node.children.first.id);
  }

  void _goToPreviousNode() {
    _setPath(state.currentPath.penultimate);
  }

  Future<void> _completePuzzle() async {
    state = state.copyWith(
      mode: PuzzleMode.view,
    );
    await _onComplete(state.result ?? PuzzleResult.win);
  }

  Future<void> _onComplete(PuzzleResult result) async {
    if (state.resultSent) return;

    state = state.copyWith(
      result: result,
      resultSent: true,
    );

    final sessionNotifier =
        puzzleSessionProvider(initialContext.userId, initialContext.theme)
            .notifier;
    final service = ref.read(defaultPuzzleServiceProvider);
    final soundService = ref.read(soundServiceProvider);

    final currentStreakIndex = state.streakIndex ?? 0;
    final nextStreakIndex = currentStreakIndex + 1;

    final next = streak == null
        ? await service.solve(
            userId: initialContext.userId,
            angle: initialContext.theme,
            solution: PuzzleSolution(
              id: state.puzzle.puzzle.id,
              win: state.result == PuzzleResult.win,
              rated: initialContext.userId != null,
            ),
          )
        : null;

    final rounds = next?.rounds;
    if (rounds != null) {
      ref.read(sessionNotifier).setRatingDiffs(rounds);
    }

    state = state.copyWith(
      nextContext: next,
      streakIndex: streak != null
          ? state.result == PuzzleResult.win
              ? nextStreakIndex
              : currentStreakIndex
          : null,
    );

    if (streak != null) {
      // one fail and streak is over
      if (result == PuzzleResult.lose) {
        soundService.play(Sound.error);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _setPath(state.currentPath.penultimate);
        _mergeSolution();
        state = state.copyWith(
          mode: PuzzleMode.view,
          nodeList: IList(_gameTree.nodesOn(state.currentPath)),
          streakFinished: true,
        );
        sendStreakResult();
      } else {
        if (_nextPuzzleFuture == null) {
          assert(false, 'next puzzle future cannot be null');
        } else {
          final nextContext = await _nextPuzzleFuture;
          if (nextContext != null) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            soundService.play(Sound.confirmation);
            continueWithNextPuzzle(nextContext);
          } else {
            state = state.copyWith(
              streakFinished: true,
            );
          }
        }
      }
    } else {
      ref.read(sessionNotifier).addAttempt(
            state.puzzle.puzzle.id,
            win: result == PuzzleResult.win,
          );
    }
  }

  void _setPath(UciPath path) {
    final newNodeList = IList(_gameTree.nodesOn(path));
    final sanMove = newNodeList.last.sanMove;
    final isForward = path.size > state.currentPath.size;
    if (isForward) {
      final isCheck = sanMove.san.contains('+');
      if (sanMove.san.contains('x')) {
        ref.read(moveFeedbackServiceProvider).captureFeedback(check: isCheck);
      } else {
        ref.read(moveFeedbackServiceProvider).moveFeedback(check: isCheck);
      }
    }
    state = state.copyWith(
      currentPath: path,
      nodeList: newNodeList,
      lastMove: sanMove.move,
    );
  }

  void _addMove(Move move) {
    final tuple = _gameTree.addMoveAt(
      state.currentPath,
      move,
      prepend: state.mode == PuzzleMode.play,
    );
    final newPath = tuple.item1;
    if (newPath != null) {
      _setPath(newPath);
    }
  }

  void _mergeSolution() {
    final initialNode = _gameTree.nodeAt(state.initialPath);
    final fromPly = initialNode.ply;
    final posAndNodes = state.puzzle.puzzle.solution.foldIndexed(
      Tuple2(initialNode.position, IList<Node>(const [])),
      (index, previous, uci) {
        final move = Move.fromUci(uci);
        final tuple = previous.item1.playToSan(move!);
        final newPos = tuple.item1;
        final newSan = tuple.item2;
        return Tuple2(
          newPos,
          previous.item2.add(
            Node(
              id: UciCharPair.fromMove(move),
              ply: fromPly + index,
              fen: newPos.fen,
              position: newPos,
              sanMove: SanMove(newSan, move),
            ),
          ),
        );
      },
    );
    _gameTree.addNodesAt(state.initialPath, posAndNodes.item2, prepend: true);
  }
}

enum PuzzleMode { play, view }

enum PuzzleResult { win, lose }

enum PuzzleFeedback { good, bad }

@freezed
class PuzzleViewModelState with _$PuzzleViewModelState {
  const PuzzleViewModelState._();

  const factory PuzzleViewModelState({
    required Puzzle puzzle,
    required PuzzleGlicko? glicko,
    required PuzzleMode mode,
    required UciPath initialPath,
    required UciPath currentPath,
    required Side pov,
    required IList<ViewNode> nodeList, // must be non empty
    Move? lastMove,
    PuzzleResult? result,
    PuzzleFeedback? feedback,
    required bool resultSent,
    required bool isChangingDifficulty,
    PuzzleContext? nextContext,
    int? streakIndex,
    bool? streakHasSkipped,
    bool? streakFinished,
  }) = _PuzzleScreenState;

  ViewNode get node => nodeList.last;
  Position get position => nodeList.last.position;
  String get fen => nodeList.last.fen;
  bool get canGoNext => mode == PuzzleMode.view && node.children.isNotEmpty;
  bool get canGoBack =>
      mode == PuzzleMode.view && currentPath.size > initialPath.size;

  IMap<String, ISet<String>> get validMoves => algebraicLegalMoves(position);
}