
// angelscript dictionaries in sven lag like shit when they have a lot of keys,
// even when not accessing them. They just generate lag without being used somehow.
// So, this is a temporary replacement.


/*
tts: Total collisions: 40415
tts: Buckets filled: 77100 / 131072 (58%)
tts: Average bucket depth: 1.524189
tts: Max bucket depth: 7
*/
uint64 hash_SDBM(string key) 
{
	uint64 hash = 0;

	for (uint c = 0; c < key.Length(); c++)
		hash = key[c] + (hash << 6) + (hash << 16) - hash;

	return hash;
}

/*
tts: Total collisions: 39905
tts: Buckets filled: 77610 / 131072 (59%)
tts: Average bucket depth: 1.514173
tts: Max bucket depth: 7
*/
uint64 hash_FNV1a(string key) 
{
	uint64 hash = 14695981039346656037;

	for (uint c = 0; c < key.Length(); c++) {
		hash = (hash * 1099511628211) ^ key[c];
	}

	return hash;
}

/*
tts: Total collisions: 40066
tts: Buckets filled: 77449 / 131072 (59%)
tts: Average bucket depth: 1.517321
tts: Max bucket depth: 7
*/
uint hash_CRC32b(string key) {
   int j;
   uint byte, crc, mask;

   crc = 0xFFFFFFFF;
   for (uint i = 0; i < key.Length(); i++) {
      byte = key[i];            // Get next byte.
      crc = crc ^ byte;
      for (j = 7; j >= 0; j--) {    // Do eight times.
         mask = -(crc & 1);
         crc = (crc >> 1) ^ (0xEDB88320 & mask);
      }
   }
   return ~crc;
}

class HashMapEntryModelInfo {
	string key;
	ModelInfo value;
	
	HashMapEntryModelInfo() {}
	
	HashMapEntryModelInfo(string key, ModelInfo value) {
		this.key = key;
		this.value = value;
	}
}

class HashMapModelInfo
{
	array<array<HashMapEntryModelInfo>> buckets;
	
	HashMapModelInfo(int size) {
		buckets.resize(size);
	}
	
	ModelInfo get(string key) {
		int idx = hash_FNV1a(key) % buckets.size();
		
		for (uint i = 0; i < buckets[idx].size(); i++) {
			if (buckets[idx][i].key == key) {
				return buckets[idx][i].value;
			}
		}
		
		return ModelInfo();
	}
	
	void put(string key, ModelInfo value) {
		int idx = hash_FNV1a(key) % buckets.size();
		
		for (uint i = 0; i < buckets[idx].size(); i++) {
			if (buckets[idx][i].key == key) {
				buckets[idx][i].value = value;
				return;
			}
		}
		
		buckets[idx].insertLast(HashMapEntryModelInfo(key, value));
	}
	
	bool exists(string key) {
		int idx = hash_FNV1a(key) % buckets.size();
		
		for (uint i = 0; i < buckets[idx].size(); i++) {
			if (buckets[idx][i].key == key) {
				return true;
			}
		}
		return false;
	}
	
	void clear(int newSize) {
		buckets.resize(0);
		buckets.resize(newSize);
	}
	
	void stats() {
		int total_collisions = 0;
		float avg_bucket_depth = 0;
		int total_filled_buckets = 0;
		uint max_bucket_depth = 0;
		
		for (uint i = 0; i < buckets.size(); i++) {
			if (buckets[i].size() > 0) {
				total_collisions += buckets[i].size()-1;
				total_filled_buckets += 1;
				avg_bucket_depth += buckets[i].size();
				max_bucket_depth = Math.max(max_bucket_depth, buckets[i].size());
			}
		}
		
		float bucket_filled_percent = float(total_filled_buckets) / buckets.size();
		
		println("Total collisions: " + total_collisions);
		println("Buckets filled: " + total_filled_buckets + " / " + buckets.size() + " (" + int(bucket_filled_percent*100) + "%%)");
		println("Average bucket depth: " + (avg_bucket_depth / float(total_filled_buckets)));
		println("Max bucket depth: " + max_bucket_depth);
	}
}