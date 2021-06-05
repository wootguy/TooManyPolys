import os, requests, json, collections

scmodels_repo_url = 'https://raw.githubusercontent.com/wootguy/scmodels/master/'
temp_path = 'scmodels_data/'
replacements_json_name = 'replacements.json'
master_json_name = temp_path + 'models.json'
versions_json_name = temp_path + 'versions.json'
alias_json_name = temp_path + 'alias.json'

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
	download_file(scmodels_repo_url + "database/alias.json", alias_json_name)
	
def update_replacement_lists():
	global replacements_json_name
	global master_json_name
	global versions_json_name
	
	model_list_path = "models.txt"
	alias_list_path = "aliases.txt"

	print("\nGenerating replacement lists")
	
	replacements = {}
	with open(replacements_json_name) as f:
		json_dat = f.read()
		replacements = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
		
	all_model_info = {}
	with open(master_json_name) as f:
		json_dat = f.read()
		all_model_info = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
	
	model_versions = {}
	with open(versions_json_name) as f:
		json_dat = f.read()
		model_versions = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
		
	aliases = {}
	with open(alias_json_name) as f:
		json_dat = f.read()
		aliases = json.loads(json_dat, object_pairs_hook=collections.OrderedDict)
	
	old_versions = set()
	old_to_latest = {}
	for ver_group in model_versions:
		all_model_info[ver_group[0]]['old_versions'] = ver_group[1:]
		old_versions.update(set(ver_group[1:]))
		for model in ver_group:
			old_to_latest[model] = ver_group[0]
		
	for model in aliases:
		all_model_info[model]['aliases'] = set(aliases[model])
	
	all_keys = list(all_model_info.keys())
	for model in all_keys:
		if model in old_versions:
			# rediret aliases of this older version to the latest version
			if 'aliases' in all_model_info[model]:
				latest_model_info = all_model_info[old_to_latest[model]]
				if 'aliases' in latest_model_info:
					latest_model_info['aliases'].update(all_model_info[model]['aliases'])
				else:
					latest_model_info['aliases'] = all_model_info[model]['aliases']
			del all_model_info[model]
	
	replace_lines = []
	alias_lines = []
	for model in all_model_info:
		polys = all_model_info[model]["polys"] if "polys" in all_model_info[model] else -1
		replace_sd = replacements[model][0] if model in replacements else ''
		replace_ld = replacements[model][1] if model in replacements else ''
		
		all_aliases = set()
		if 'old_versions' in all_model_info[model]:
			all_aliases.update(all_model_info[model]['old_versions'])
		if 'aliases' in all_model_info[model]:
			all_aliases.update(all_model_info[model]['aliases'])
		all_aliases = list(all_aliases)
		
		if len(all_aliases) > 0:
			all_aliases.sort()
			alias_lines.append("%s/%s\n" % (model, '/'.join(all_aliases)))
			
		replace_lines.append("%s/%s/%s/%s\n" % (model, polys, replace_sd, replace_ld))
	
	replace_lines.sort()
	alias_lines.sort()
	
	model_list = open(model_list_path, "w")
	for line in replace_lines:
		model_list.write(line)
	model_list.close()
	print("Wrote %s" % model_list_path)
	
	alias_list = open(alias_list_path, "w")
	for line in alias_lines:
		alias_list.write(line)
	alias_list.close()
	print("Wrote %s" % alias_list_path)
	
update_scmodels_data()
update_replacement_lists()