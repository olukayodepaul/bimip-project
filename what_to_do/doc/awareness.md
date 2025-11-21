# **Awareness Message — Documentation**

## **Overview**

Awareness is responsible **only** for broadcasting presence (ONLINE/OFFLINE/AWAY/BUSY/DND) and optional location sharing. It does *not* handle typing, recording, or viewing — those belong to the Signal system.
Awareness is used to fetch all offline messages in a single bulk pull request when a device comes back online.

---

## **Status Codes**

```
1 = ONLINE
2 = OFFLINE
3 = AWAY
4 = BUSY
5 = DND
```

## **Message Definition**

```proto
message Awareness {
  string id = 1;
  Identity from = 2;
  Identity to = 3;
  int32 type = 4;
  int32 status = 5;
  int32 location_sharing = 6;
  double latitude = 7;
  double longitude = 8;
  int32 ttl = 9;
  string details = 10;
  int64 timestamp = 11;
  int32 visibility = 12;
}
```
