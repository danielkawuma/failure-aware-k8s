#!/usr/bin/env python3
"""Generate a pinned, fail-closed controller config from a live pre-fault snapshot."""
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
out = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/openmrs-cd-config.json')
def get(*args):
    return json.loads(subprocess.check_output(['kubectl', *args, '-o', 'json'], text=True))
namespace=os.getenv('OPENMRS_CD_NAMESPACE','openmrs37')
deployment=os.getenv('OPENMRS_CD_DEPLOYMENT','openmrs-mariadb')
selector=os.getenv('OPENMRS_CD_SELECTOR','app=openmrs-mariadb')
d = get('get','deployment',deployment,'-n',namespace)
pods = get('get','pods','-n',namespace,'-l',selector)['items']
active = [p for p in pods if p['status'].get('phase')=='Running' and not p['metadata'].get('deletionTimestamp')]
if len(active)!=1 or d['spec'].get('replicas')!=1:
    raise SystemExit('Require exactly one active MariaDB Pod and one desired replica')
pod=active[0]; original=pod['spec']['nodeName']
if d['spec']['template']['metadata'].get('labels',{}).get('failure-aware.io/duplication-sensitive')!='true':
    raise SystemExit('Missing duplication-sensitive label')
node=get('get','node',original)
ips=[x['address'] for x in node['status']['addresses'] if x['type']=='InternalIP']
if len(ips)!=1: raise SystemExit('Original node IP ambiguous')
candidates=[]
for n in get('get','nodes')['items']:
    name=n['metadata']['name']
    if name==original or 'node-role.kubernetes.io/control-plane' in n['metadata'].get('labels',{}) or n['spec'].get('unschedulable'): continue
    if n['metadata'].get('labels',{}).get('failure-aware.io/role')!='recovery-candidate': continue
    if not any(c['type']=='Ready' and c['status']=='True' for c in n.get('status',{}).get('conditions',[])): continue
    candidates.append(name)
if not candidates: raise SystemExit('No ready recovery candidate')
preferred=os.environ.get('OPENMRS_CD_CANDIDATE') or sorted(candidates)[0]
if preferred not in candidates: raise SystemExit(f'Candidate {preferred} is not eligible: {candidates}')
# Existing controller currently evaluates one configured candidate. Do not claim dynamic ranking here.
config={
 'target_node':original, 'trigger_ready_status':'Unknown',
 'verification_url':f'http://127.0.0.1:{int(os.environ.get("OPENMRS_DB_PROBE_HTTP_PORT", "18086"))}/health',
 'verification_timeout_ms':2000,'verification_attempts':3,'verification_interval_ms':500,
 'workload_name':deployment,'workload_type':'database','duplication_sensitive':True,
 'service_criticality':'high','namespace':namespace,'pod_label_selector':selector,
 'recovery_candidate_node':preferred,'required_cpu_millicores':300,'required_memory_mib':512,
 'required_node_labels':{'failure-aware.io/role':'recovery-candidate'},
 'fencing_supported':True,'fencing_timeout_ms':120000,
 'fencing_command':f'env SSH_KEY={os.environ.get("SSH_KEY",str(pathlib.Path.home()/".ssh/k8s-aware"))} OPENMRS_CD_ORIGINAL_NODE={original} OPENMRS_CD_ORIGINAL_IP={ips[0]} {root}/scripts/openmrs-cd-fence-original.sh fence'
}
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(config,indent=2)+'\n')
(out.parent/(out.stem+'-authority.json')).write_text(json.dumps({'node':original,'ip':ips[0],'pod':pod['metadata']['name'],'candidate':preferred,'pod_ip':pod['status']['podIP']},indent=2)+'\n')
print(f'CONFIG={out}\nORIGINAL={original} {ips[0]}\nCANDIDATE={preferred}\nNO_FAULT_APPLIED')
