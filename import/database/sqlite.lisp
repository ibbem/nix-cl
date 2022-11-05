(defpackage org.lispbuilds.nix/database/sqlite
  (:use :cl)
  (:import-from :str)
  (:import-from :sqlite)
  (:import-from :alexandria :read-file-into-string)
  (:import-from :alexandria-2 :line-up-first)
  (:import-from :arrow-macros :->>)
  (:import-from
   :org.lispbuilds.nix/util
   :replace-regexes)
  (:import-from
   :org.lispbuilds.nix/nix
   :nix-eval
   :nixify-symbol
   :system-master
   :make-pname
   :*nix-attrs-depth*)
  (:import-from
   :org.lispbuilds.nix/api
   :database->nix-expression)
  (:export :sqlite-database :init-db)
  (:local-nicknames
   (:json :com.inuoe.jzon)))

(in-package org.lispbuilds.nix/database/sqlite)

(defclass sqlite-database ()
  ((url :initarg :url
        :reader database-url
        :initform (error "url required"))
   (init-file :initarg :init-file
              :reader init-file
              :initform (error "init file required"))))

(defun init-db (db init-file)
  (let ((statements (->> (read-file-into-string init-file)
                         (replace-regexes '(".*--.*") '(""))
                         (substitute #\Space #\Newline)
                         (str:collapse-whitespaces)
                         (str:split #\;)
                         (mapcar #'str:trim)
                         (remove-if #'str:emptyp))))
    (sqlite:with-transaction db
      (dolist (s statements)
        (sqlite:execute-non-query db s)))))


;; Writing Nix

(defparameter prelude "
# This file was auto-generated by nix-quicklisp.lisp

{ runCommand, pkgs, fetchzip, ... }:

let

 inherit (builtins) getAttr;

# Ensures that every non-slashy `system` exists in a unique .asd file.
# (Think cl-async-base being declared in cl-async.asd upstream)
#
# This is required because we're building and loading a system called
# `system`, not `asd`, so otherwise `system` would not be loadable
# without building and loading `asd` first.
#
 createAsd = { url, sha256, asd, system }:
   let
     src = fetchzip { inherit url sha256; };
   in runCommand \"source\" {} ''
      mkdir -pv $out
      cp -r ${src}/* $out
      find $out -name \"${asd}.asd\" | while read f; do mv -fv $f $(dirname $f)/${system}.asd || true; done
  '';
in {")

(defmethod database->nix-expression ((database sqlite-database) outfile)
  (sqlite:with-open-database (db (database-url database))
    (with-open-file (f outfile
                       :direction :output
                       :if-exists :supersede)

      ;; Fix known problematic packages before dumping the nix file.
      (sqlite:execute-non-query db
       "create temp table fixed_systems as select * from system_view")

      (sqlite:execute-non-query db
       "alter table fixed_systems add column systems")

      (sqlite:execute-non-query db
       "update fixed_systems set systems = json_array(name)")

      (sqlite:execute-non-query db
       "alter table fixed_systems add column asds")

      (sqlite:execute-non-query db
       "update fixed_systems set asds = json_array(name)")

      (sqlite:execute-non-query db
       "delete from fixed_systems where name in ('asdf', 'uiop')")

      (format f prelude)

      (dolist (p (sqlite:execute-to-list db "select * from fixed_systems"))
        (destructuring-bind (name version asd url sha256 deps systems asds) p
          (format f "~%  ")
          (let ((*nix-attrs-depth* 1))
            (format
             f
             "~a = ~a;"
             (nix-eval `(:symbol ,name))
             (nix-eval
              `(:attrs
                ("pname" (:string ,(make-pname name)))
                ("version" (:string ,version))
                ("asds" (:list
                         ,@(mapcar (lambda (asd)
                                     `(:string ,(system-master asd)))
                                   (coerce (json:parse asds) 'list))))
                ("src" (:funcall
                        "createAsd"
                        (:attrs
                         ("url" (:string ,url))
                         ("sha256" (:string ,sha256))
                         ("system" (:string ,(system-master name)))
                         ("asd" (:string ,asd)))))
                ("systems" (:list
                            ,@(mapcar (lambda (sys)
                                        `(:string ,sys))
                                      (coerce (json:parse systems) 'list))))
                ("lispLibs" (:list
                             ,@(mapcar (lambda (dep)
                                         `(:funcall
                                           "getAttr"
                                           (:string ,(nixify-symbol dep))
                                           (:symbol "pkgs")))
                                       (line-up-first
                                        (str:split-omit-nulls #\, deps)
                                        (set-difference '("asdf" "uiop") :test #'string=)
                                        (sort #'string<)))))
                ,@(when (find #\/ name)
                    '(("meta" (:attrs ("broken" (:symbol "true"))))))))))))
      (format f "~%}"))))
