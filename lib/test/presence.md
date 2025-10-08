message Logout {
Identity to = 1; // The user/device performing logout
int32 type = 2; // 1 = REQUEST, 2 = RESPONSE
int32 status = 3; // 1 = DISCONNECT, 2 = FAIL, 3 = SUCCESS, 4 = PENDING
int64 timestamp = 4; // Unix UTC timestamp (ms)
string reason = 5; // Optional: description if FAIL
}
