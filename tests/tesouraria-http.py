import urllib.request, urllib.error, time, collections, sys
base=sys.argv[1].rstrip('/') # URL do gateway DESCARTÁVEL, sem tráfego legítimo
def req(path,method='GET',headers=None,host='tesouraria.localhost',data=None):
 h={'Host':host,**(headers or {})}
 try:
  with urllib.request.urlopen(urllib.request.Request(base+path,headers=h,method=method,data=data),timeout=5) as r:return r.status
 except urllib.error.HTTPError as e:return e.code
assert req('/healthz',host='outro.localhost')==200
for path in ['/api/v1/auth/login','/api/v1/users','/api/v1/auth/forgot-password','/api/v1/auth/resend-verification','/api/v1/auth/reset-password','/api/v1/auth/verify-email']:
 time.sleep(1)
 codes=[req(path,headers={'X-Forwarded-For':f'192.0.2.{i+1}','X-Real-IP':f'192.0.2.{i+1}','Forwarded':f'for=192.0.2.{i+1}'}) for i in range(3)]
 assert codes[0]!=429 and codes[-1]==429,(path,codes)
 print(path,codes,'headers falsificados não evitam 429')
time.sleep(1)
codes=[req('/inc5-inexistente') for _ in range(12)]
assert 429 in codes,codes
print('geral',dict(collections.Counter(codes)))
assert all(req('/',host='outro.localhost')==404 for _ in range(12))
assert req('/healthz',host='outro.localhost')==200
print('default: 12 x 404; healthz: 200')
time.sleep(1)
# URI com query fictícia e métodos sem operações sobre contas.
for method in ['GET','HEAD','OPTIONS','PUT','PATCH','DELETE','POST']:
 status=req('/inc5-inexistente?token=INC5_QUERY_SENTINEL',method,headers={'Authorization':'Bearer INC5_AUTH_SENTINEL'})
 assert status!=429,(method,status)
 print('backend método',method,status)
 time.sleep(.15)
assert req('/inc5-inexistente','POST',data=b'x'*65537)==413
print('corpo >64KiB: 413')
