package aws.dynamodb;

import aws.dynamodb.DynamoDBError;
import aws.dynamodb.DynamoDBException;
import aws.dynamodb.RecordInfos;
import haxe.crypto.Base64;

using Lambda;

class Manager<T:sys.db.Object> {
	
	static inline var SERVICE:String = "DynamoDB";
	static inline var API_VERSION:String = "20120810";
	
	#if !macro
	public static var cnx:Connection;
	#end
	
	var cls:Class<T>;

	public function new (cls:Class<T>) {
		this.cls = cls;
	}
	
	public macro function get (ethis, id, ?consistent:haxe.macro.Expr.ExprOf<Bool>): #if macro haxe.macro.Expr #else haxe.macro.Expr.ExprOf<T> #end {
		return RecordMacros.macroGet(ethis, id, consistent);
	}
	
	public macro function search (ethis, cond, ?options, ?consistent:haxe.macro.Expr.ExprOf<Bool>): #if macro haxe.macro.Expr #else haxe.macro.Expr.ExprOf<List<T>> #end {
		return RecordMacros.macroSearch(ethis, cond, options, consistent);
	}
	
	public macro function select (ethis, cond, ?options, ?consistent:haxe.macro.Expr.ExprOf<Bool>): #if macro haxe.macro.Expr #else haxe.macro.Expr.ExprOf<List<T>> #end {
		return RecordMacros.macroSearch(ethis, cond, options, consistent, true);
	}
	
	#if !macro
	public function getInfos ():RecordInfos {
		return untyped cls.__dynamodb_infos;
	}
	
	function getFieldType (name:String):RecordType {
		var infos = getInfos();
		
		for (i in infos.fields) {
			if (i.name == name) {
				return i.type;
			}
		}
		
		return null;
	}
	
	function encodeVal (val:Dynamic, type:RecordType):{t:String, v:Dynamic} {
		return switch (type) {
			case DString: {t:"S", v:val};
			case DFloat, DInt: {t:"N", v:Std.string(val)};
			case DBool: {t:"N", v:(val ? "1" : "0")};
			case DDate:
				var date = cast(val, Date);
				date = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0);
				{t:"N", v:Std.string(date.getTime())};
			case DDateTime: {t:"N", v:Std.string(cast(val, Date).getTime())};
			case DTimeStamp: {t:"N", v:Std.string(val)};
			case DBinary: {t:"B", v:Base64.encode(val)};
			case DEnum(e): { t:"N", v:Std.string(val) };
			case DSet(t):
				var dtype = switch (t) {
					case DString: "SS";
					case DBinary: "BS";
					default: "NS";
				}
				var list = new Array<Dynamic>();
				for (i in cast(val, List<Dynamic>)) {
					list.push(encodeVal(i, t).v);
				}
				if (list.length == 0) throw "Set must contain at least one value.";
				{t:dtype, v:list};
		};
	}
	
	public function haxeToDynamo (name:String, v:Dynamic):Dynamic {
		var obj:Dynamic = { };
		var ev = encodeVal(v, getFieldType(name));
		
		Reflect.setField(obj, ev.t, ev.v);
		
		return obj;
	}
	
	function decodeVal (val:Dynamic, type:RecordType):Dynamic {
		return switch (type) {
			case DString: val;
			case DFloat: Std.parseFloat(val);
			case DInt: Std.parseInt(val);
			case DBool: val == "1";
			case DDate, DDateTime: Date.fromTime(Std.parseFloat(val));
			case DTimeStamp: Std.parseFloat(val);
			case DBinary: Base64.decode(val);
			case DEnum(e): Std.parseInt(val);
			case DSet(t):
				var list = new List<Dynamic>();
				for (i in cast(val, Array<Dynamic>)) {
					list.add(decodeVal(i, t));
				}
				list;
		};
	}
	
	public function dynamoToHaxe (name:String, v:Dynamic):Dynamic {
		var infos = getInfos();
		
		for (i in Reflect.fields(v)) {
			var val = Reflect.field(v, i);
			return decodeVal(val, getFieldType(name));
		}
		
		throw "Unknown DynamoDB type.";
	}
	
	function buildSpodObject (item:Dynamic):T {
		var infos = getInfos();
		
		var spod = Type.createInstance(cls, []);
		for (i in Reflect.fields(item)) {
			if (infos.fields.exists(function (e) { return e.name == i; } )) Reflect.setField(spod, i, dynamoToHaxe(i, Reflect.field(item, i)));
		}
		return spod;
	}
	
	function getTableName (?shardDate:Date):String {
		var infos = getInfos();
		if (shardDate == null) shardDate = Date.now();
		
		var str = "";
		if (infos.prefix != null) {
			str += infos.prefix;
		}
		str += infos.table;
		if (infos.shard != null) {
			str += DateTools.format(shardDate, infos.shard);
		}
		return str;
	}
	
	public function unsafeGet (id:Dynamic, ?consistent:Bool = false):T {
		var infos = getInfos();
		var keys:Dynamic = { };
		Reflect.setField(keys, infos.primaryIndex.hash, id);
		return unsafeGetWithKeys(keys, consistent);
	}
	
	public function unsafeGetWithKeys (keys:Dynamic, ?consistent:Bool = false):T {
		var dynkeys:Dynamic = { };
		for (i in Reflect.fields(keys)) {
			Reflect.setField(dynkeys, i, haxeToDynamo(i, Reflect.field(keys, i)));
		}
		return buildSpodObject(cnx.sendRequest("GetItem", {
			TableName: getTableName(),
			ConsistentRead: consistent,
			Key: dynkeys
		}).Item);
	}
	
	public function unsafeObjects (query:Dynamic, ?consistent:Bool = false):List<T> {
		Reflect.setField(query, "TableName", getTableName());
		Reflect.setField(query, "ConsistentRead", consistent);
		return Lambda.map(cast(cnx.sendRequest("Query", query).Items, Array<Dynamic>), function (e) { return buildSpodObject(e); } );
	}
	
	function checkKeyExists (spod:T, index:RecordIndex):Void {
		if (Reflect.field(spod, index.hash) == null) throw "Missing hash.";
		if (index.range != null) {
			if (Reflect.field(spod, index.range) == null) throw "Missing range.";
		}
	}
	
	function buildRecordExpected (spod:T, index:RecordIndex, exists:Bool):Dynamic {
		var obj:Dynamic = { };
		
		var hash = { Exists:exists };
		if (exists) Reflect.setField(hash, "Value", haxeToDynamo(index.hash, Reflect.field(spod, index.hash)));
		Reflect.setField(obj, index.hash, hash);
		if (index.range != null) {
			var range = { Exists:exists };
			if (exists) Reflect.setField(range, "Value", haxeToDynamo(index.range, Reflect.field(spod, index.range)));
			Reflect.setField(obj, index.range, range);
		}
		
		return obj;
	}
	
	function buildFields (spod:T):Dynamic {
		var infos = getInfos();
		var fields:Dynamic = { };
		
		for (i in infos.fields) {
			var v = Reflect.field(spod, i.name);
			if (v != null) {
				if (Std.is(v, String) && cast(v, String).length == 0) throw "String values must have length greater than 0.";
				
				Reflect.setField(fields, i.name, haxeToDynamo(i.name, v));
			}
		}
		
		return fields;
	}
	
	public function doInsert (obj:T):Void {
		var infos = getInfos();
		checkKeyExists(obj, infos.primaryIndex);
		
		cnx.sendRequest("PutItem ", {
			TableName: getTableName(),
			Expected: buildRecordExpected(obj, infos.primaryIndex, false),
			Item: buildFields(obj)
		});
	}
	
	public function doUpdate (obj:T):Void {
		var infos = getInfos();
		checkKeyExists(obj, infos.primaryIndex);
		
		cnx.sendRequest("PutItem ", {
			TableName: getTableName(),
			Expected: buildRecordExpected(obj, infos.primaryIndex, true),
			Item: buildFields(obj)
		});
	}
	
	public function doPut (obj:T):Void {
		var infos = getInfos();
		checkKeyExists(obj, infos.primaryIndex);
		
		cnx.sendRequest("PutItem ", {
			TableName: getTableName(),
			Item: buildFields(obj)
		});
	}
	
	public function doDelete (obj:T):Void {
		var infos = getInfos();
		checkKeyExists(obj, infos.primaryIndex);
		
		var key = { };
		Reflect.setField(key, infos.primaryIndex.hash, haxeToDynamo(infos.primaryIndex.hash, Reflect.field(obj, infos.primaryIndex.hash)));
		if (infos.primaryIndex.range != null) Reflect.setField(key, infos.primaryIndex.range, haxeToDynamo(infos.primaryIndex.range, Reflect.field(obj, infos.primaryIndex.range)));
		
		cnx.sendRequest("DeleteItem ", {
			TableName: getTableName(),
			Key: key
		});
	}
	
	public function doSerialize( field : String, v : Dynamic ) : haxe.io.Bytes {
		var s = new haxe.Serializer();
		s.useEnumIndex = true;
		s.serialize(v);
		var str = s.toString();
		#if neko
		return neko.Lib.bytesReference(str);
		#else
		return haxe.io.Bytes.ofString(str);
		#end
	}

	public function doUnserialize( field : String, b : haxe.io.Bytes ) : Dynamic {
		if( b == null )
			return null;
		var str;
		#if neko
		str = neko.Lib.stringReference(b);
		#else
		str = b.toString();
		#end
		if( str == "" )
			return null;
		return haxe.Unserializer.run(str);
	}
	
	public function objectToString (o:T):String {
		return Std.string(o);
	}
	
	public function createTable (?shardDate:Date):Void {
		var infos = getInfos();
		
		var attrFields = new Array<String>();
		
		var key = new Array<Dynamic>();
		key.push( { AttributeName:infos.primaryIndex.hash, KeyType:"HASH" } );
		attrFields.push(infos.primaryIndex.hash);
		if (infos.primaryIndex.range != null) {
			key.push( { AttributeName:infos.primaryIndex.range, KeyType:"RANGE" } );
			attrFields.push(infos.primaryIndex.range);
		}
		
		var globalIndexes = new Array<Dynamic>();
		var localIndexes = new Array<Dynamic>();
		for (i in infos.indexes) {
			var key = new Array<Dynamic>();
			key.push( { AttributeName:i.index.hash, KeyType:"HASH" } );
			if (i.index.range != null) key.push( { AttributeName:infos.primaryIndex.range, KeyType:"RANGE" } );
			
			if (i.global) {
				globalIndexes.push( {
					IndexName: i.name,
					KeySchema: key,
					Projection: { ProjectionType: "ALL" },
					ProvisionedThroughput: {
						ReadCapacityUnits: i.readCap != null ? i.readCap : 1,
						WriteCapacityUnits: i.writeCap != null ? i.writeCap : 1
					}
				} );
			} else {
				localIndexes.push( {
					IndexName: i.name,
					KeySchema: key,
					Projection: { ProjectionType: "ALL" }
				} );
			}
		}
		
		var fields = new Array<Dynamic>();
		for (i in infos.fields) {
			if (attrFields.has(i.name)) {
				var type = switch (i.type) {
					case DString: "S";
					case DBinary: "B";
					case DSet(t):
						switch (t) {
							case DString: "SS";
							case DBinary: "BS";
							default: "NS";
						}
					default: "N";
				};
				
				fields.push( {
					AttributeName: i.name,
					AttributeType: type
				} );
			}
		}
		
		var req = {
			TableName: getTableName(shardDate),
			ProvisionedThroughput: {
				ReadCapacityUnits: infos.readCap != null ? infos.readCap : 1,
				WriteCapacityUnits: infos.writeCap != null ? infos.writeCap : 1
			},
			KeySchema: key,
			AttributeDefinitions: fields
		};
		
		if (globalIndexes.length > 0) Reflect.setField(req, "GlobalSecondaryIndexes", globalIndexes);
		if (localIndexes.length > 0) Reflect.setField(req, "LocalSecondaryIndexes", localIndexes);
		
		cnx.sendRequest("CreateTable", req);
	}
	
	public function deleteTable (?shardDate:Date):Void {
		cnx.sendRequest("DeleteTable", { TableName:getTableName(shardDate) } );
	}
	#end
	
}