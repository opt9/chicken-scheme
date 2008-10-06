;;;; collect cross-module inlining candidates


(define (node->sexpr n)
  (let walk ((n n))
    `(,(node-class n)
      ,(node-parameters n)
      ,@(map walk (node-subexpressions n)))))


(define (collect-cmi-candidates node db)
  (let ((collected '()))
    (define (exported? var)
      (and (##compiler#get db var 'global)
	   (not (##compiler#get db var 'standard-binding))
	   (not (##compiler#get db var 'extended-binding))
	   (or (memq var ##compiler#export-list)
	       (not (memq var ##compiler#block-globals)))))
    (define (walk n e le k dest)
      (let ((params (node-parameters n))
	    (subs (node-subexpressions n)))
	;(pp `(WALK: ,(node-class n) ,e ,le))
	(case (node-class n)
	  ((##core#variable) 
	   (let ((var (car params)))
	     (cond ((memq var e) #t)
		   ((memq var le) 1)	; references lexical variable
		   ((exported? var) #t)
		   (else #f))))
	  ((let)
	   (let* ((r (walk (car subs) e le k #f))
		  (r2 (walk (cadr subs) (cons (car params) e) le k dest)))
	     (cond ((eq? r 1) (and r2 1))
		   (r r2)
		   (else #f))))
	  ((##core#lambda)
	   (##compiler#decompose-lambda-list
	    (third params)
	    (lambda (vars argc rest)
	      (let ((k (and (pair? vars) (car vars))))
		(cond ((walk (car subs) vars (append e le) k #f) =>
		       (lambda (r)
			 ;; if lambda doesn't refer to outer lexicals, collect
			 (when (and dest
				    (not (eq? 1 r))
				    (not (memq dest ##compiler#not-inline-list))
				    (or (memq dest ##compiler#not-inline-list)
					(<= (fourth params) ##compiler#inline-max-size)))
			   (set! collected (alist-cons dest n collected)))
			 #t))
		      (else #f))))))
	  ((set!)
	   (let ((var (car params)))
	     (walk (car subs) e le k (and (exported? var) var))))
	  ((##core#callunit) #f)
	  ((##core#call)
	   ;; only allow continuation-calls (i.e. returns) and self-recursion
	   (and (eq? '##core#variable (node-class (car subs)))
		(let ((var (car (node-parameters (car subs)))))
		  (or (eq? var k)
		      (eq? var dest)))
		(every (cut walk <> e le k #f) subs)))
	  ((if)
	   (and (walk (first subs) e le k #f)
		(walk (second subs) e le k dest)
		(walk (third subs) e le k dest)))
	  (else (every (cut walk <> e le k #f) subs)))))
    (walk node '() '() #f #f)
    (for-each 
     (lambda (p)
       (display "#,")
       (pp `(node ,(car p) ,(node->sexpr (cdr p))))
       (newline))
     collected)))

(user-post-optimization-pass collect-cmi-candidates)