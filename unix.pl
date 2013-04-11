/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 1985-2013, University of Amsterdam
			      VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(unix,
	  [ fork/1,			% -'client'|pid
	    exec/1,			% +Command(...Args...)
	    fork_exec/1,		% +Command(...Args...)
	    wait/2,			% -Pid, -Reason
	    kill/2,			% +Pid. +Signal
	    pipe/2,			% +Read, +Write
	    dup/2,			% +From, +To
	    detach_IO/0,
	    detach_IO/1,		% +Stream
	    environ/1			% -[Name=Value]
	  ]).
:- use_module(library(shlib)).

/** <module> Unix specific operations

The library(unix) library provides the commonly  used Unix primitives to
deal with process management.  These  primitives   are  useful  for many
tasks, including server management, parallel computation, exploiting and
controlling other processes, etc.

The predicates in this library are   modelled closely after their native
Unix counterparts.

@see library(process) provides a portable high level interface to create
and manage processes.
*/

:- use_foreign_library(foreign(unix), install_unix).

%%	fork(-Pid) is det.
%
%	Clone the current process into two   branches. In the child, Pid
%	is unified to child. In the original  process, Pid is unified to
%	the process identifier of the  created   child.  Both parent and
%	child are fully functional  Prolog   processes  running the same
%	program. The processes share open I/O streams that refer to Unix
%	native streams, such as files, sockets   and  pipes. Data is not
%	shared, though on most Unix systems data is initially shared and
%	duplicated only if one of the   programs  attempts to modify the
%	data.
%
%	Unix fork() is the only way to   create new processes and fork/1
%	is a simple direct interface to it.
%
%	@error	permission_error(fork, process, main) is raised if
%		the calling thread is not the only thread in the
%		process.  Forking a Prolog process with threads
%		will typically deadlock because only the calling
%		thread is cloned in the fork, while all thread
%		synchronization are cloned.

fork(Pid) :-
	fork_warn_threads,
	fork_(Pid).

%%	fork_warn_threads
%
%	See whether we are the  only thread.  If not, we cannot fork

fork_warn_threads :-
	findall(T, other_thread(T), Others),
	(   Others == []
	->  true
	;   throw(error(permission_error(fork, process, main),
			context(_, running_threads(Others))))
	).

other_thread(T) :-
	thread_self(Me),
	thread_property(T, status(Status)),
	T \== Me,
	(   Status == running
	->  true
	;   print_message(warning, fork(join(T, Status))),
	    thread_join(T, _),
	    fail
	).

%%	fork_exec(+Command) is det.
%
%	Fork (as fork/1) and exec (using  exec/1) the child immediately.
%	This behaves as the code below, but   bypasses the check for the
%	existence of other threads because this is a safe scenario.
%
%	  ==
%	  fork_exec(Command) :-
%		(   fork(child)
%		->  exec(Command)
%		;   true
%		).
%	  ==

fork_exec(Command) :-
	(   fork_(child)
	->  exec(Command)
	;   true
	).

%%	exec(+Command)
%
%	Replace the running program by starting   Command.  Command is a
%	callable term. The functor is  the   command  and  the arguments
%	provide  the  command-line  arguments  for   the  command.  Each
%	command-line argument must be  atomic  and   is  converted  to a
%	string before passed to the Unix   call  execvp(). Here are some
%	examples:
%
%	  - exec(ls('-l'))
%	  - exec('/bin/ls'('-l', '/home/jan'))
%
%	Unix exec() is  the  only  way   to  start  an  executable  file
%	executing. It is commonly used together with fork/1. For example
%	to start netscape on an URL in the background, do:
%
%	  ==
%	  run_netscape(URL) :-
%		  (    fork(child),
%		       exec(netscape(URL))
%		  ;    true
%		  ).
%	  ==
%
%	Using this code, netscape remains part   of the process-group of
%	the invoking Prolog  process  and  Prolog   does  not  wait  for
%	netscape to terminate. The predicate wait/2 allows waiting for a
%	child, while detach_IO/0  disconnects  the   child  as  a deamon
%	process.


%%	wait(-Pid, -Status) is det.
%
%	Wait for a child to change status.   Then  report the child that
%	changed status as well as  the   reason.  Status is unified with
%	exited(ExitCode) if the child with  pid   Pid  was terminated by
%	calling exit() (Prolog halt/1). ExitCode   is the return status.
%	Status is unified with signaled(Signal) if the child died due to
%	a software interrupt (see kill/2).   Signal  contains the signal
%	number. Finally, if the process  suspended   execution  due to a
%	signal, Status is unified with stopped(Signal).

%%	kill(+Pid, +Signal) is det.
%
%	Deliver a software interrupt to the  process with identifier Pid
%	using software-interrupt number Signal.   See  also on_signal/2.
%	Signals can be specified as  an   integer  or signal name, where
%	signal names are derived from  the   C  constant by dropping the
%	=SIG= prefix and mapping to lowercase. E.g. =int= is the same as
%	=SIGINT= in C. The meaning of the signal numbers can be found in
%	the Unix manual.

%%	pipe(-InSream, -OutStream) is det.
%
%	Create a communication-pipe. This is  normally   used  to make a
%	child communicate to its parent. After   pipe/2,  the process is
%	cloned and, depending on the   desired direction, both processes
%	close the end of the pipe they  do   not  use. Then they use the
%	remaining stream to communicate. Here is a simple example:
%
%	  ==
%	  :- use_module(library(unix)).
%
%	  fork_demo(Result) :-
%		  pipe(Read, Write),
%		  fork(Pid),
%		  (   Pid == child
%		  ->  close(Read),
%		      format(Write, '~q.~n',
%			     [hello(world)]),
%		      flush_output(Write),
%		      halt
%		  ;   close(Write),
%		      read(Read, Result),
%		      close(Read)
%		  ).
%	  ==


%%	dup(+FromStream, +ToStream) is det.
%
%	Interface to Unix dup2(), copying  the underlying filedescriptor
%	and thus making both  streams  point   to  the  same  underlying
%	object. This is normally used together with fork/1 and pipe/2 to
%	talk to an external program  that   is  designed  to communicate
%	using standard I/O.
%
%	Both FromStream and ToStream either refer  to a Prolog stream or
%	an  integer  descriptor  number   to    refer   directly  to  OS
%	descriptors. See also demo/pipe.pl in the source-distribution of
%	this package.


%%	detach_IO(+Stream) is det.
%
%	This predicate is intended to create Unix _deamon_ processes. It
%	performs two actions.
%
%	  1. The I/O streams =user_input=, =user_output= and
%	  =user_error= are closed if they are connected to a terminal
%	  (see =tty= property in stream_property/2). Input streams are
%	  rebound to a dummy stream that returns EOF. Output streams are
%	  reboud to forward their output to Stream.
%
%	  2. The process is detached from the current process-group and
%	  its controlling terminal. This is achieved using setsid() if
%	  provided or using ioctl() =TIOCNOTTY= on =|/dev/tty|=.
%
%	To ignore all output, it may be   rebound  to a null stream. For
%	example:
%
%	  ==
%		...,
%		open_null_stream(Out),
%		detach_IO(Out).
%	  ==
%
%	The  detach_IO/1  should  be  called   only  once  per  process.
%	Subsequent calls silently succeed without any side effects.
%
%	@see detach_IO/0.

%%	detach_IO is det.
%
%	Detach I/O similar to detach_IO/1. The  output streams are bound
%	to a file =|/tmp/pl-out.<pid>|=. Output   is  line buffered (see
%	set_stream/2).
%
%	@compat	Older versions of this predicate only created this file
%		if there was output.
%	@tbd	If should be possible to use the syslog facilities for
%		writing messages.

detach_IO :-
	current_prolog_flag(pid, Pid),
	atom_concat('/tmp/pl-out.', Pid, TmpFile),
	open(TmpFile, write, Out, [alias(daemon_output)]),
	set_stream(Out, buffer(line)),
	detach_IO(Out).


		 /*******************************
		 *	     MESSAGES		*
		 *******************************/

:- multifile
	prolog:message//1.

prolog:message(fork(join(T, Status))) -->
	[ 'Fork: joining thead ~p (status: ~p)'-[T, Status] ].
