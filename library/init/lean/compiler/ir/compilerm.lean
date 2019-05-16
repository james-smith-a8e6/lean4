/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import init.control.reader
import init.lean.environment
import init.lean.compiler.ir.basic
import init.lean.compiler.ir.format

namespace Lean
namespace IR

inductive LogEntry
| step (cls : Name) (decls : Array Decl)
| message (msg : Format)

namespace LogEntry
protected def fmt : LogEntry → Format
| (step cls decls) := Format.bracket "[" (format cls) "]" ++ decls.foldl (λ fmt decl, fmt ++ Format.line ++ format decl) Format.nil
| (message msg)    := msg

instance : HasFormat LogEntry := ⟨LogEntry.fmt⟩
end LogEntry

abbrev Log := Array LogEntry

@[export lean.ir.format_log_core]
def formatLog (log : Log) : Format :=
log.foldl (λ fmt entry, fmt ++ Format.line ++ format entry) Format.nil

structure CompilerState :=
(env : Environment) (log : Log := Array.empty)

abbrev CompilerM := ReaderT Options (EState String CompilerState)

def log (entry : LogEntry) : CompilerM Unit :=
modify $ λ s, { log := s.log.push entry, .. s }

def tracePrefixOptionName := `trace.compiler.ir

private def isLogEnabledFor (opts : Options) (optName : Name) : Bool :=
match opts.find optName with
| some (DataValue.ofBool v) := v
| other := opts.getBool tracePrefixOptionName

private def logDeclsAux (optName : Name) (cls : Name) (decls : Array Decl) : CompilerM Unit :=
do opts ← read,
   when (isLogEnabledFor opts optName) $ log (LogEntry.step cls decls)

@[inline] def logDecls (cls : Name) (decl : Array Decl) : CompilerM Unit :=
logDeclsAux (tracePrefixOptionName ++ cls) cls decl

private def logMessageIfAux {α : Type} [HasFormat α] (optName : Name) (a : α) : CompilerM Unit :=
do opts ← read,
   when (isLogEnabledFor opts optName) $ log (LogEntry.message (format a))

@[inline] def logMessageIf {α : Type} [HasFormat α] (cls : Name) (a : α) : CompilerM Unit :=
logMessageIfAux (tracePrefixOptionName ++ cls) a

@[inline] def logMessage {α : Type} [HasFormat α] (cls : Name) (a : α) : CompilerM Unit :=
logMessageIfAux tracePrefixOptionName a

@[inline] def modifyEnv (f : Environment → Environment) : CompilerM Unit :=
modify $ λ s, { env := f s.env, .. s }

abbrev DeclMap := SMap Name Decl Name.quickLt

/- Create an array of decls to be saved on .olean file.
   `decls` may contain duplicate entries, but we assume the one that occurs last is the most recent one. -/
private def mkEntryArray (decls : List Decl) : Array Decl :=
/- Remove duplicates by adding decls into a map -/
let map : HashMap Name Decl := {} in
let map := decls.foldl (λ (map : HashMap Name Decl) decl, map.insert decl.name decl) map in
map.fold (λ a k v, a.push v) Array.empty

def mkDeclMapExtension : IO (PersistentEnvExtension Decl DeclMap) :=
registerPersistentEnvExtension {
  name       := `IRDecls,
  initState  := {},
  addEntryFn := λ init s d,
    let s := if init then s else s.switch in
    s.insert d.name d,
  toArrayFn  := mkEntryArray,
  lazy       := false }

@[init mkDeclMapExtension]
constant declMapExt : PersistentEnvExtension Decl DeclMap := default _

def findDecl (n : Name) : CompilerM (Option Decl) :=
do s ← get,
   pure $ (declMapExt.getState s.env).find n

def containsDecl (n : Name) : CompilerM Bool :=
do s ← get,
   pure $ (declMapExt.getState s.env).contains n

def getDecl (n : Name) : CompilerM Decl :=
do (some decl) ← findDecl n | throw ("unknown declaration '" ++ toString n ++ "'"),
   pure decl

def addDecl (decl : Decl) : CompilerM Unit :=
modifyEnv (λ env, declMapExt.addEntry env decl)

def addDecls (decls : Array Decl) : CompilerM Unit :=
decls.mfor addDecl

end IR
end Lean
