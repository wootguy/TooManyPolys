import os, requests, json, collections

scmodels_repo_url = 'https://raw.githubusercontent.com/wootguy/scmodels/master/'
temp_path = 'scmodels_data/'
replacements_json_name = 'replacements.json'
master_json_name = temp_path + 'models.json'
versions_json_name = temp_path + 'versions.json'

def download_file(url, out_path):
	print(url + " --> " + out_path)
	r = requests.get(url, allow_redirects=True)
	
	if r.status_code == 404:
		print("404 - file not found. Aborting.")
		sys.exit()
		
	open(out_path, 'wb').write(r.content)

def update_scmodels_data():
	global master_json_name
	global versions_json_name
	
	print("Downloading model info rom scmodels repo")
	
	if not os.path.exists(temp_path):
		os.makedirs(temp_path)

	download_file(scmodels_repo_url + "database/models.json", master_json_name)
	download_file(scmodels_repo_url + "database/versions.json", versions_json_name)
	
def update_replacement_lists():
	global replacements_json_name
	global master_json_name
	global versions_json_name
	
	model_list_path = "models.txt"

	print("\nGenerating replacement lists")
	
	replacements = {}
	with open(replacements_json_name) as f:
		json_dat = f.read()
		replacements = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
		
	model_info = {}
	with open(master_json_name) as f:
		json_dat = f.read()
		model_info = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
	
	model_versions = {}
	with open(versions_json_name) as f:
		json_dat = f.read()
		model_versions = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
	
	old_versions = set()
	for ver_group in model_versions:
		model_info[ver_group[0]]['old_versions'] = ver_group[1:]
		old_versions.update(set(ver_group[1:]))		
	
	all_keys = list(model_info.keys())
	for model in all_keys:
		if model in old_versions:
			del model_info[model]
	
	
	all_lines = []
	for model in model_info:
		polys = model_info[model]["polys"] if "polys" in model_info[model] else -1
		replace_sd = replacements[model][0] if model in replacements else ''
		replace_ld = replacements[model][1] if model in replacements else ''
		
		all_versions = [model]
		if 'old_versions' in model_info[model]:
			all_versions += model_info[model]['old_versions']
			
		for version in all_versions:
			all_lines.append("%s/%s/%s/%s\n" % (version, polys, replace_sd, replace_ld))
	
	all_lines.sort()
	
	model_list = open(model_list_path, "w")
	for line in all_lines:
		model_list.write(line)
	model_list.close()
	
	print("Wrote %s" % model_list_path)
	
update_scmodels_data()
update_replacement_lists()