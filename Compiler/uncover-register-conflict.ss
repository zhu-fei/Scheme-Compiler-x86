
(library (Compiler uncover-register-conflict)
         (export uncover-register-conflict parse-LuncoverRegisterConflict)
         (import
          (chezscheme)
          (source-grammar)
          (Framework nanopass)
          (Framework helpers))

         (define-parser parse-LuncoverRegisterConflict LuncoverRegisterConflict)

         (define-pass uncover-register-conflict : LverifyScheme (x) -> LuncoverRegisterConflict ()
           (definitions

             (define init-conflict-table
               (lambda (ls)
                 (map list ls)))

             (define conflict-table '())
             (define live-ls '())

             (define update-table
               (lambda (var cf* cf-ls)
                 (let* ([found (assq var cf-ls)]
                        [rest (cdr found)]
                        [conflicts (union cf* rest)])
                   (begin (set-cdr! found conflicts)
                          (for-each (lambda (v)
                                 (if (uvar? v)
                                     (let* ([check (list var)]
                                            [found (assq v cf-ls)]
                                            [rest (cdr found)]
                                            [conflicts (union check rest)])
                                       (set-cdr! found conflicts))))
                                 cf*) cf-ls))))
             (define remove-frame-var
               (lambda (ls)
                 (cond
                   ((null? ls) '())
                   ((or (label? (car ls)) (frame-var? (car ls))) (remove-frame-var (cdr ls)))
                   (else (cons (car ls) (remove-frame-var (cdr ls)))))))

             (define Ef*
               (lambda (ef*)
                   (reverse (map Effect (reverse ef*))))))

           (Prog : Prog (x) -> Prog ()
                 [(letrec ([,l* ,[le*]] ...) ,[bd]) `(letrec ([,l* ,le*] ...) ,bd)]
                 [else (error who "something went wrong - Prog")])
           (LambdaExpr : LambdaExpr (x) -> LambdaExpr ()
                       [(lambda () ,[bd]) `(lambda () ,bd)]
                       [else (error who "something went wrong - LambdaExpr")])
           (Body : Body (x) -> Body ()
                 [(locals (,uv* ...) ,tl) (begin
                                              (set! conflict-table (init-conflict-table uv*))
                                              (let ([a (Tail tl)])
                                                (display conflict-table)
                                              `(locals (,uv* ...) (register-conflict ,conflict-table ,a))))]
                 [else (error who "something went wrong - Body")])
           (Tail : Tail (x) -> Tail ()
                 [(,triv ,locrf* ...) (begin
                                        
                                        (set! live-ls (remove-frame-var (cons triv locrf*)))
                                        
                                        (in-context Tail `(,triv ,locrf* ...)))]
                 [(begin ,ef* ... ,tl) (begin
                                         (let ([a (Tail tl)]
                                               [b (Ef* ef*)])
                                         `(begin ,b ... ,a)))]
                 [(if ,pred ,tl0 ,tl1) (begin
                                         (let ([a (Tail tl1)]
                                               [b (Tail tl0)]
                                               [c (Pred pred)])
                                         `(if ,c ,b ,a)))]
                 [else (error who "something went wrong - Tail")])
           (Pred : Pred (x) -> Pred ()
                 [(true) `(true)]
                 [(false) `(false)]
                 [(,relop ,triv0 ,triv1) (begin
                                           (if (or (register? triv0) (uvar? triv0))
                                               (set! live-ls (set-cons triv0 live-ls)))
                                           (if (or (register? triv1) (uvar? triv1))
                                               (set! live-ls (set-cons triv1 live-ls)))
                                           `(,relop ,triv0 ,triv1))]
                 [(if ,pred0 ,pred1 ,pred2) (begin
                                              (let ([a (Pred pred2)]
                                                    [b (Pred pred1)]
                                                    [c (Pred pred0)])
                                              `(if ,c ,b ,a)))]
                 [(begin ,ef* ... ,pred) (begin
                                           (let ([a (Pred pred)]
                                                 [b (Ef* ef*)])
                                           `(begin ,b ... ,a)))]
                 [else (error who "something went wrong - Pred")])
           (Effect : Effect (x) -> Effect ()
                   [(nop) `(nop)]
                   [(set! ,v ,triv) (begin                                                                              
                                      (set! live-ls (remv v live-ls))
                                      (cond
                                       ((uvar? v) (update-table v live-ls conflict-table))
                                       ((register? v) (for-each
                                                       (lambda (x) (if (uvar? x)
                                                        (set! conflict-table (update-table x (list v) conflict-table))))
                                                       live-ls)))
                                      (let ([a (Triv triv)])
                                        (if (frame-var? v) (set! live-ls (remove triv live-ls)))
                                      `(set! ,v ,a)))]
                   [(set! ,v (,op ,triv1 ,triv2)) (begin
                                                    
                                                    (set! live-ls (remv v live-ls))
                                                    (cond
                                                     ((uvar? v) (update-table v live-ls conflict-table))
                                                     ((register? v) (for-each
                                                                     (lambda (x) (if (uvar? x)
                                                        (set! conflict-table (update-table x (list v) conflict-table))))
                                                                     live-ls)))
                                                    (let ([a (Triv triv2)]
                                                          [b (Triv triv1)])
                                                      (if (frame-var? v) (set! live-ls (remove triv1 (remove triv2 live-ls))))
                                                    `(set! ,v (,op ,b ,a))))]
                   [(if ,pred ,ef1 ,ef2) (begin
                                           (let ([a (Effect ef2)]
                                                 [b (Effect ef1)]
                                                 [c (Pred pred)])
                                           `(if ,c ,b ,a)))]
                   [(begin ,ef* ... ,ef) (begin
                                           (let ([a (Effect ef)]
                                                 [b (Ef* ef*)])
                                           `(begin ,b ... ,a)))]
                   [else (error who "something went wrong - Effect")])
           (Triv : Triv (x) -> Triv ()
                 [,v (if (or (register? v) (uvar? v)) (set! live-ls (set-cons v live-ls)))
                     `,v]
                 [,i `,i]
                 [,l `,l]))
) ;End Library









