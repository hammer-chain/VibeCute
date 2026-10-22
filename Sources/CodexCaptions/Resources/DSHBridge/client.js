window.__ModuleLoader__.load({
  id: '@local/vibecute-approval-bridge-v11',
  factory() {
    return {
      inject: ['remote', 'uiWorkspace', 'uiSession', 'sessions'],
      apply(ctx) {
        const answeredCards = new WeakSet();
        ctx.remote.$on('vibecute/status', (_request, next) => {
          if (globalThis.location?.protocol !== 'dsh-app:' || globalThis.location?.host !== 'app') return next();
          return {clientVersion:'v11'};
        });
        ctx.remote.$on('vibecute/question', async (request, next) => {
          if (globalThis.location?.protocol !== 'dsh-app:' || globalThis.location?.host !== 'app') return next();
          const { sessionID, id } = request;
          if (typeof sessionID !== 'string' || !/^session-[0-9a-f-]{36}$/i.test(sessionID) || typeof id !== 'string') return {status:'stale', id};
          // Use the existing live card, including requests issued before this bridge loaded.
          const exposed = ctx.uiSession;
          const ui = exposed?.[Symbol.for('cordis.original')] ?? exposed;
          const card = ui?.pendingSnapshot?.get(sessionID);
          if (!card || card.sessionId !== sessionID || (card.callId !== undefined && card.callId !== id) || card.review !== undefined
              || typeof card.answer !== 'function' || card.getSnapshot?.().closed || answeredCards.has(card)) return {status:'stale', id};
          const canonical = rows => rows.map(q => ({id:q.id, question:q.question, multiSelect:!!(q.multiSelect ?? q.multi_select),
            options:(q.options ?? []).map(o => ({label:o.label, description:o.description ?? ''}))}));
          const questions = canonical(card.questions);
          if (card.callId === undefined && (!Array.isArray(request.legacyQuestions)
              || JSON.stringify(canonical(request.legacyQuestions)) !== JSON.stringify(questions))) return {status:'stale',id};
          if (request.operation === 'question-status') return {status:'ok', id, questions};
          if (request.operation !== 'question-answer' || !Array.isArray(request.questions)
              || JSON.stringify(canonical(request.questions)) !== JSON.stringify(questions)
              || !Array.isArray(request.answers) || request.answers.length !== questions.length) return {status:'stale', id};
          const seen = new Set();
          for (const answer of request.answers) {
            const question = card.questions.find(q => q.id === answer.id);
            if (!question || seen.has(answer.id) || question.intent
                || !Array.isArray(answer.selected) || answer.selected.length < 1
                || (!question.multiSelect && answer.selected.length !== 1) || answer.custom !== undefined
                || new Set(answer.selected).size !== answer.selected.length
                || !answer.selected.every(label => (question.options ?? []).some(o => o.label === label))) return {status:'stale', id};
            seen.add(answer.id);
          }
          if (card.getSnapshot?.().channel === 'none' || request.signal?.aborted) return {status:'stale', id};
          answeredCards.add(card);
          try {
            await card.answer({answers:request.answers});
            return {status:'ok', id};
          } catch { return {status:'uncertain', id}; }
        });
        ctx.remote.$on('vibecute/navigate', (request, next) => {
          if (globalThis.location?.protocol !== 'dsh-app:' || globalThis.location?.host !== 'app') return next();
          const id = request.sessionID;
          if (typeof id !== 'string' || !/^session-[0-9a-f-]{36}$/i.test(id)) return { opened: false };
          const summary = ctx.sessions.list.getSnapshot().byId[id];
          if (!summary) return { opened: false, sessionID: id };
          ctx.uiWorkspace.openSession(id);
          return { opened: ctx.uiWorkspace.mainReference?.sessionId === id, sessionID: id };
        });
      }
    };
  }
});
