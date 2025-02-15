MODULE WMMessages; (** AUTHOR "TF"; PURPOSE "Support for messages and events"; *)

IMPORT
	Strings, KernelLog, Objects, Kernel, Locks, Modules, Reflection, SYSTEM, D:= Debugging;

CONST
	InitialMsgQSize = 64;
	MaxMsgQSize = 32*1024; (* this is too huge anyway *)
	(** Predefined Messages *)
	MsgPointer* = 0; MsgKey* = 2; MsgClose* = 3; MsgStyleChanged* = 4;
	MsgFocus* = 5; MsgExt* = 6; MsgDrag* = 7;
	MsgInvokeEvent* = 8;
	MsgResized* = 9;
	MsgSetLanguage* = 10;
	MsgInvalidate*= 11;
	MsgSerialize*=12;
	MsgMerged*=15;

	MsgSubPointerMove* = 0; MsgSubPointerDown* = 1; MsgSubPointerUp* = 2; MsgSubPointerLeave* = 3;
	MsgSubFocusGot* = 0; MsgSubFocusLost* = 1; MsgSubMasterFocusGot* = 2; MsgSubMasterFocusLost* = 3;

	MsgSubAll*=0; MsgSubRectangle*=1; MsgSubNothing*=2; (* regions: all or rectangle as defined by x, y, dx, dy *)

	MsgDragOver* = 0; MsgDragDropped* = 1;

	MsgSubSerializeView*=0; MsgSubSerializeComponent*=1; MsgSubSerializeData*=2;

	(** Gather statistics about added/discarded messages? *)
	Statistics* = FALSE;
	TraceQueue = FALSE;
	MsgTypeMax* = 13;


TYPE
	(** Generic Component Command *)
	CompCommand* = PROCEDURE  { DELEGATE } (sender, par : ANY);
	String* = Strings.String;

	(** Generic message structure *)
	Message* = RECORD
		originator*, (** the originator if # NIL passes information about the view that directly or indirectely lead to the msg *)
		sender* : ANY; (** is the sender component. If the message is originated form a component *)
		token* : AsyncToken;
		event* : CompCommand;
		msgType*, msgSubType* : SIGNED32; (** generic message type *)
		x*, y*, z*, dx*, dy*, dz* : SIZE; (** in keyboard messages : ucs value in x, keysym in y *)
		flags* : SET; (** in pointer messages : keys in flags *)
		ext* : ANY; (** extended message *)
	END;

	MessageExtension* = POINTER TO RECORD END;

	(** AsyncToken can be used to synchronize asynchronous method invocation *)
	AsyncToken* = OBJECT
	VAR
		ready : BOOLEAN;
		result* : ANY;

		(** Reset is called in case the token was recycled *)
		PROCEDURE Reset*;
		BEGIN {EXCLUSIVE}
			ready := FALSE;
		END Reset;

		(** wait until the result is completed *)
		PROCEDURE AwaitCompletion*;
		BEGIN {EXCLUSIVE}
			AWAIT(ready)
		END AwaitCompletion;

		(** Return if the result is completed *)
		PROCEDURE IsCompleted*():BOOLEAN;
		BEGIN {EXCLUSIVE}
			RETURN ready
		END IsCompleted;

		(** Called by the asynchronous process to indicate the result is available *)
		PROCEDURE Completed*;
		BEGIN {EXCLUSIVE}
			ready := TRUE
		END Completed;
	END AsyncToken;


	(** Message handler that can be called from the sequencer *)
	MessageHandler* = PROCEDURE {DELEGATE} (VAR msg : Message);

	(** The TrapHandler must return TRUE if the process should restart. Otherwise the process is stopped *)
	TrapHandler* = PROCEDURE {DELEGATE} () : BOOLEAN;

	MsgQ = RECORD
		head, num: SIZE;
		msgQ: POINTER TO ARRAY OF Message;
		owner: MsgSequencer;

		PROCEDURE Init(o: MsgSequencer; size: SIZE);
		BEGIN
			head := 0; num := 0;
			NEW(msgQ, size);
			SELF.owner := o;
		END Init;

		PROCEDURE Grow(trace: BOOLEAN);
		VAR new: POINTER TO ARRAY (* MsgQSize*)  OF Message; i: SIZE; name: ARRAY 128 OF CHAR; VAR pc: ADDRESS;
			type: Modules.TypeDesc; msg: Message;
		BEGIN
			NEW(new, LEN(msgQ) * 3 DIV 2);
			FOR i := 0 TO LEN(msgQ)-1 DO
				new[i] := msgQ[(head+i) MOD LEN(msgQ)];
				IF trace THEN
					msg := new[i];
					IF msg.msgType < LEN(MsgName) THEN COPY(MsgName[msg.msgType], name) ELSE name := "" END;
					TRACE(i,"***************", name);
					TRACE(i, msg.msgType, msg.msgSubType);
					TRACE(msg.x, msg.y, msg.dx, msg.dy, msg.flags);
					IF msg.sender # NIL THEN
						type := Modules.TypeOf(msg.sender);
						IF (type # NIL) THEN
							COPY(type.mod.name, name); Strings.Append(name, "."); Strings.Append(name, type.name);
							TRACE(msg.sender, name);
						ELSE
							TRACE(msg.sender);
						END;
					END;
					IF msg.msgType = MsgInvokeEvent THEN
						Reflection.GetProcedureName(ADDRESS(msg.event), name, pc );
						TRACE("Event procedure ", name);
					END;
					IF msg.ext # NIL THEN
						type := Modules.TypeOf(msg.ext);
						IF (type # NIL) THEN
							COPY(type.mod.name, name); Strings.Append(name, "."); Strings.Append(name, type.name);
							TRACE(msg.ext, name);
						ELSE
							TRACE(msg.ext);
						END;
					END;
				END;
			END;
			msgQ := new;	head := 0;
			KernelLog.String("MessageQ increased: "); KernelLog.Int(LEN(msgQ),1); KernelLog.Ln;
		END Grow;

		(** Add a message to a queue. Discards the message if the queue is full *)
		PROCEDURE Add(VAR msg : Message; debug:BOOLEAN): BOOLEAN;
		VAR i, pos: SIZE; name: ARRAY 256 OF CHAR; pc: ADDRESS;
		type: Modules.TypeDesc;
		CONST
			MergePointers = TRUE;
			MergeInvalidates = TRUE;
			MergeInvokeEvents = FALSE;

			PROCEDURE Merge(VAR x,y,dx,dy: SIZE; X,Y,dX,dY: SIZE);
			VAR nx, ny, ndx, ndy: SIZE;
			BEGIN
				nx := MIN(x,X);
				ny := MIN(y,Y);
				ndx := MAX(x+dx, X+dX) - nx;
				ndy := MAX(y+dy, Y+dY) - ny;
				x := nx;
				y := ny;
				dx := ndx;
				dy := ndy;
			END Merge;


		BEGIN
			IF debug  THEN
				KernelLog.String("<----");
				IF msg.msgType < LEN(MsgName) THEN COPY(MsgName[msg.msgType], name) ELSE name := "" END;
				TRACE("WMMessages.MsgSequencer.Add", name);
				TRACE(num, msg.msgType, msg.msgSubType);
				TRACE(msg.x, msg.y, msg.dx, msg.dy);
				IF msg.sender # NIL THEN
					type := Modules.TypeOf(msg.sender);
					IF (type # NIL) THEN
						COPY(type.mod.name, name); Strings.Append(name, "."); Strings.Append(name, type.name);
						TRACE(msg.sender, name);
					ELSE
						TRACE(msg.sender);
					END;
				END;
				IF msg.msgType = MsgInvokeEvent THEN
					Reflection.GetProcedureName(ADDRESS(msg.event), name, pc );
					TRACE("Event procedure ", name);
				END;
				IF msg.ext # NIL THEN
					type := Modules.TypeOf(msg.ext);
					IF (type # NIL) THEN
						COPY(type.mod.name, name); Strings.Append(name, "."); Strings.Append(name, type.name);
						TRACE(msg.ext, name);
					ELSE
						TRACE(msg.ext);
					END;
				END;
				(*D.TraceBack;*)
			END;

			IF MergePointers & (msg.msgType = MsgPointer) & (msg.msgSubType = MsgSubPointerMove) & (num > 0) THEN  (* reduce pointer moves in buffer *)
				i := num - 1;
				WHILE i >= 0 DO
					pos := (head + i) MOD LEN(msgQ);
					IF (msgQ[pos].msgType = MsgPointer) & (msgQ[pos].msgSubType = MsgSubPointerMove) & (msgQ[pos].flags = msg.flags) THEN
						msgQ[pos].x := msg.x;
						msgQ[pos].y := msg.y;
						msgQ[pos].z := msg.z;
						RETURN TRUE
					END;
					DEC(i)
				END
			END;



			(* filter out duplicate MsgInvokeEvents - was a hack (but effecting in avoiding MessageQ congestion)*)
			IF MergeInvokeEvents & (msg.msgType = MsgInvokeEvent) & (msg.msgSubType = 0) & (num > 0) THEN
				i := num - 1;
				WHILE i >= 0 DO
					pos := (head + i) MOD LEN(msgQ);
					IF (msgQ[pos].msgType = MsgInvokeEvent) & (msgQ[pos].msgSubType = 0) & (msgQ[pos].event = msg.event)& (msgQ[pos].sender = msg.sender) & (msgQ[pos].ext = msg.ext) THEN
						msgQ[pos].msgType := MsgMerged;
					END;
					DEC(i)
				END
			END;

			IF MergeInvalidates & (msg.msgType = MsgInvalidate) & (num > 0)  THEN
				i := num-1;
				pos := (head + i) MOD LEN(msgQ);
				IF (msgQ[pos].sender = msg.sender) & (msgQ[pos].msgType = MsgInvalidate) & (msgQ[pos].msgSubType = msg.msgSubType) THEN
					IF msg.msgSubType= MsgSubRectangle THEN
						IF Contained(msgQ[pos], msg) THEN
							IF TraceQueue OR debug THEN
								TRACE("container first ", msg.x, msg.dx, msg.y, msg.dy);
								TRACE(msgQ[pos].x, msgQ[pos].dx, msgQ[pos].y, msgQ[pos].dy);
								KernelLog.Ln;
							END;
							(* replace *)
							msgQ[pos].x := msg.x; msgQ[pos].y := msg.y; msgQ[pos].dx := msg.dx; msgQ[pos].dy := msg.dy;
							RETURN TRUE;
						ELSIF Contained(msg, msgQ[pos]) THEN
							IF TraceQueue OR debug THEN
								TRACE("contained first ", msg.x, msg.dx, msg.y, msg.dy);
								TRACE(msgQ[pos].x, msgQ[pos].dx, msgQ[pos].y, msgQ[pos].dy);
								KernelLog.Ln;
							END;
							(* keep *)
							RETURN TRUE;
						ELSE (* we assume that invaidates on the same component
									that immediately follow each other are very close to each other
									If this turns out to be untrue, we could add a heuristics here *)
								Merge(msgQ[pos].x, msgQ[pos].y, msgQ[pos].dx, msgQ[pos].dy, msg.x, msg.y, msg.dx, msg.dy);
								(* keep *)
								RETURN TRUE;
						END;
					ELSIF msg.msgSubType = MsgSubAll THEN
						(* keep *)
						IF TraceQueue OR debug THEN
							TRACE("keep first");
							KernelLog.Ln;
						END;
						RETURN TRUE;
					END;
				END;

				DEC(i);
				WHILE i >= 0 DO
					pos := (head + i) MOD LEN(msgQ);
					IF (msgQ[pos].sender = msg.sender) & (msgQ[pos].msgType = MsgInvalidate) & (msgQ[pos].msgSubType = msg.msgSubType) THEN
						IF msg.msgSubType= MsgSubRectangle THEN
							IF Contained(msgQ[pos], msg) THEN
								IF TraceQueue OR debug THEN
									TRACE("container  ", pos);
									TRACE( msg.x, msg.dx, msg.y, msg.dy);
									TRACE(msgQ[pos].x, msgQ[pos].dx, msgQ[pos].y, msgQ[pos].dy);
								END;

								msgQ[pos].msgType := MsgMerged;
								i := 0;
							ELSIF Contained(msg, msgQ[pos]) THEN
								IF TraceQueue OR debug  THEN
									TRACE("contained  ", pos);
									TRACE(msg.x, msg.dx, msg.y, msg.dy);
									TRACE(msgQ[pos].x, msgQ[pos].dx, msgQ[pos].y, msgQ[pos].dy);
								END;

								msg.x := msgQ[pos].x; msg.y := msgQ[pos].y; msg.dx := msgQ[pos].dx; msg.dy := msgQ[pos].dy;
								msgQ[pos].msgType := MsgMerged;
								i := 0;
							(*ELSE
								Merge(msg.x, msg.y, msg.dx, msg.dy, msgQ[pos].x, msgQ[pos].y, msgQ[pos].dx, msgQ[pos].dy);
								msgQ[pos].msgSubType := MsgSubNothing;
							*)
							END;
						ELSIF msgQ[pos].msgSubType = MsgSubAll THEN
							IF TraceQueue OR debug  THEN
								TRACE("replace ", pos);
							END;
								msgQ[pos].msgType := MsgMerged;
							i := 0;
						END;
					END;
					DEC(i);
				END;
			END;


			IF num >= MaxMsgQSize THEN RETURN FALSE END;
			IF num >= LEN(msgQ) THEN
				Grow(debug)
			END;
			IF Statistics THEN
				INC(messagesAdded);
				IF (msg.msgType >= 0) & (msg.msgType < MsgTypeMax) THEN
					INC(messagesAddedByType[msg.msgType]);
				END;
			END;
			msgQ[(head + num) MOD LEN(msgQ)] := msg; INC(num);

			IF debug  THEN
				KernelLog.Ln;
			END;

			RETURN TRUE;
		END Add;

		(* Remove a message from the queue. Block if no message is available but awake if queue is terminated by call to Stop *)
		(* return if alive *)
		PROCEDURE Get(VAR msg : Message; debug: BOOLEAN) : BOOLEAN;
		VAR i: SIGNED32; name: ARRAY 256 OF CHAR; pc: ADDRESS;
			type: Modules.TypeDesc;
		BEGIN
			msg := msgQ[head];
			(* clear references from the queue *)
			msgQ[head].originator := NIL;
			msgQ[head].sender := NIL;
			msgQ[head].ext := NIL;

			head := (head + 1)  MOD LEN(msgQ);
			DEC(num);
			owner.originator := msg.originator;

			IF debug THEN
				KernelLog.String("---->");
				IF msg.msgType < LEN(MsgName) THEN COPY(MsgName[msg.msgType], name) ELSE name := "" END;
				TRACE("WMMessages.MsgSequencer.Get", name);
				TRACE(i, msg.msgType, msg.msgSubType);
				TRACE(msg.x, msg.y, msg.dx, msg.dy);
				IF msg.sender # NIL THEN
					type := Modules.TypeOf(msg.sender);
					IF (type # NIL) THEN
						COPY(type.mod.name, name); Strings.Append(name, "."); Strings.Append(name, type.name);
						TRACE(msg.sender, name);
					ELSE
						TRACE(msg.sender);
					END;
				END;
				IF msg.msgType = MsgInvokeEvent THEN
					Reflection.GetProcedureName(ADDRESS(msg.event), name, pc );
					TRACE("Event procedure ", name);
				END;
				IF msg.ext # NIL THEN
					type := Modules.TypeOf(msg.ext);
					IF (type # NIL) THEN
						COPY(type.mod.name, name); Strings.Append(name, "."); Strings.Append(name, type.name);
						TRACE(msg.ext, name);
					ELSE
						TRACE(msg.ext);
					END;
				END;
				KernelLog.Ln;
			END;


			RETURN TRUE
		END Get;

	END (*MsgQ*);

	(** Message sequencer *)
	MsgSequencer* = OBJECT
	VAR
		msgQ: MsgQ;
		invalidateQ: MsgQ;
		alive, continue, waiting, stopped: BOOLEAN;
		msg : Message;
		handler : MessageHandler;
		originator : ANY;
		me : ANY; (* Thread for caller identification *)
		lock- : Locks.RWLock;
		th, traphandler : TrapHandler;
		name* : String;

		PROCEDURE &New*(handler : MessageHandler);
		BEGIN
			SELF.handler := handler;
			NEW(lock);
			originator := NIL; me := NIL; th := NIL; traphandler := NIL;
			name := NIL;
			alive := FALSE; continue := TRUE;
			waiting := FALSE; stopped := FALSE;
			invalidateQ.Init(SELF, InitialMsgQSize);
			msgQ.Init(SELF, InitialMsgQSize);
		END New;

		(** Add a trap handler for this process. This handler only decides whether to continue or to abort the process.
			If continued, the lock will be reset *)
		PROCEDURE SetTrapHandler*(th : TrapHandler);
		BEGIN {EXCLUSIVE}
			traphandler := th
		END SetTrapHandler;

		(** Return true if called from (this) sequencer *)
		PROCEDURE IsCallFromSequencer*() : BOOLEAN;
		BEGIN
			RETURN Objects.ActiveObject() = me
		END IsCallFromSequencer;

		(** RETURN the originator (view) of the message that lead directly or indirectly to this request.
			Returns NIL if the call is not from the sequencer  *)
		PROCEDURE GetOriginator*() : ANY;
		BEGIN
			IF Objects.ActiveObject() = me THEN RETURN originator
			ELSE RETURN NIL
			END
		END GetOriginator;

		(** Add a message to a queue. Discards the message if the queue is full *)
		PROCEDURE Add*(VAR msg : Message): BOOLEAN;
		BEGIN {EXCLUSIVE}
			IF msg.msgType = MsgInvalidate THEN
				RETURN invalidateQ.Add(msg, TraceQueue OR (debug = SELF));
			ELSE
				RETURN msgQ.Add(msg, TraceQueue OR (debug = SELF));
			END;
		END Add;

		PROCEDURE Handle(VAR msg : Message) : BOOLEAN;
		BEGIN
			(* if asynchronous call --> synchronize *)
			IF ~IsCallFromSequencer() THEN
				IF Add(msg) THEN RETURN TRUE END;
			ELSE
				(*
				IF debug = SELF THEN
					D.Enter;
					D.Ln;
					D.String("-- WMMessages.MsgSequencer.Handle --"); D.Ln;
					D.String("msg type "); D.Int(msg.msgType,1); D.Ln;
					D.String("time "); D.Int(Kernel.GetTicks(),1);D.Ln;
					D.Exit;
				END;
				*)

				IF msg.msgType = MsgInvokeEvent THEN (* MsgInvokeEvent *)
					IF msg.event # NIL THEN
						msg.event(msg.sender, msg.ext);
						IF msg.token # NIL THEN msg.token.Completed END
					END
				ELSE handler(msg) (* Generic message *)
				END;
				(* clear references *)
				msg.originator := NIL;
				msg.sender := NIL;
				msg.ext := NIL;
				originator := NIL;
				RETURN TRUE
			END;
			RETURN FALSE
		END Handle;

		(* put event into message queue *)
		PROCEDURE ScheduleEvent*(event : CompCommand; sender, par : ANY);
		VAR invokeMsg : Message;
		BEGIN
			invokeMsg.msgType := MsgInvokeEvent;
			invokeMsg.sender := sender; invokeMsg.ext := par;
			invokeMsg.event := event;
			IF ~Handle(invokeMsg) THEN END
		END ScheduleEvent;

		(** Stop the message sequencer. Must be called if the queue is no longer needed *)
		PROCEDURE Stop*;
		BEGIN {EXCLUSIVE}
			alive := FALSE; stopped := TRUE;
		END Stop;

		PROCEDURE WaitFree*;
		BEGIN {EXCLUSIVE}
			AWAIT (waiting & (msgQ.num = 0) & (invalidateQ.num = 0) OR ~alive)
		END WaitFree;

		(* Remove a message from the queue. Block if no message is available but awake if queue is terminated by call to Stop *)
		(* return if alive *)
		PROCEDURE Get(VAR msg : Message) : BOOLEAN;
		VAR b: BOOLEAN;
		BEGIN {EXCLUSIVE}
			waiting := TRUE;
			REPEAT
				AWAIT((msgQ.num # 0) OR (invalidateQ.num # 0) OR ~alive);
				waiting := FALSE;
				IF ~alive THEN RETURN FALSE END;
				IF (msgQ.num # 0) THEN
					b := msgQ.Get(msg, TraceQueue OR (debug = SELF));
				ELSE
					 b := invalidateQ.Get(msg, TraceQueue OR (debug = SELF));
				END;
			UNTIL msg.msgType # MsgMerged;
			RETURN b;
		END Get;

	BEGIN {ACTIVE, SAFE}
		(* trap occured *)
		IF alive THEN
			th := traphandler; KernelLog.String("WMMessages: [TRAP]"); KernelLog.Ln;
			IF th # NIL THEN continue := th() ELSE continue := FALSE END;
			IF continue THEN lock.Reset ELSE RETURN END;
		END;
		alive := TRUE; me := Objects.ActiveObject();
		(* Message processing loop *)
		WHILE Get(msg) DO
			lock.AcquireWrite;
			(* Check alive again for the case that the sequencer has been stopped just after Get(msg) returned
			but before the lock could be acquired (WMComponents.FormWindow holds that lock when calling Sequencer.Stop) *)
			IF alive THEN
				IF ~Handle(msg) THEN KernelLog.String("WMMessages: A msg was not handled... "); KernelLog.Ln; END;
			END;
			lock.ReleaseWrite
		END
	END MsgSequencer;

VAR
	 tokenCache : Kernel.FinalizedCollection;
	 ttoken : AsyncToken;

	 (* Statistics *)
	 messagesAddedByType- : ARRAY MsgTypeMax OF SIGNED32;
	 messagesAdded- : SIGNED32;
	 messagesDiscarded- : SIGNED32;


	 debug*: ANY;
	 MsgName: ARRAY 32 OF ARRAY 32 OF CHAR;


PROCEDURE TokenEnumerator(obj: ANY; VAR cont: BOOLEAN);
BEGIN
	cont := FALSE; ttoken := obj(AsyncToken)
END TokenEnumerator;

(** Get an AsyncToken from the pool. Create a new one if the pool is empty *)
PROCEDURE GetAsyncToken*() : AsyncToken;
BEGIN {EXCLUSIVE}
	ttoken := NIL;
	tokenCache.Enumerate(TokenEnumerator);
	IF ttoken = NIL THEN NEW(ttoken)
	ELSE tokenCache.Remove(ttoken)
	END;
	ttoken.Reset;
	RETURN ttoken
END GetAsyncToken;

(** Recycle an AsyncToken. Must be unused. (is only used to disburden the garbage collector) *)
PROCEDURE RecycleAsyncToken*(t : AsyncToken);
BEGIN
	(* only recycle the token if the result is complete *)
	IF t.IsCompleted() THEN tokenCache.Add(t, NIL) END;
END RecycleAsyncToken;

PROCEDURE Contained(CONST this, container: Message): BOOLEAN;
BEGIN
	RETURN (container.x <= this.x) & (container.dx >= this.dx) & (container.y <= this.y) & (container.dy >= this.dy)
END Contained;

BEGIN
	NEW(tokenCache);
	MsgName[MsgPointer] := "MsgPointer";
	MsgName[MsgKey] := "MsgKey";
	MsgName[MsgClose] := "MsgClose";
	MsgName[MsgStyleChanged] := "MsgStyleChanged";
	MsgName[MsgFocus] := "MsgFocus";
	MsgName[MsgExt] := "MsgExt";
	MsgName[MsgDrag] := "MsgDrag";
	MsgName[MsgInvokeEvent] := "MsgInvokeEvent";
	MsgName[MsgResized] := "MsgResized" ;
	MsgName[MsgSetLanguage] := "MsgSetLanguage";
	MsgName[MsgInvalidate] := "MsgInvalidate";
	MsgName[MsgSerialize] := "MsgSerialize";
END WMMessages.


Release.Rebuild  --path="" Win32 WMMessages.Mod ~
