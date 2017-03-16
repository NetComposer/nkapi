-ifndef(NKAPU_HRL_).
-define(NKAPU_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================




%% ===================================================================
%% Records
%% ===================================================================

-record(nkapi_req, {
	srv_id :: nkservice:id(),
	class :: nkapi:class(),
	subclass = '' :: nkapi:subclass(),
	cmd = '' :: nkapi:cmd(),
	data = #{} :: nkapi:data(),
	tid :: term(),
	user_id = <<>> :: binary(),
	session_id = <<>> :: binary()
}).


-endif.

