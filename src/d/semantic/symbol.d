module d.semantic.symbol;

import d.semantic.base;
import d.semantic.semantic;

import d.ast.adt;
import d.ast.dfunction;
import d.ast.declaration;
import d.ast.dscope;
import d.ast.dtemplate;
import d.ast.expression;
import d.ast.type;

import std.algorithm;
import std.array;
import std.conv;

// TODO: change ast to allow any statement as function body, then remove that import.
import d.ast.statement;

final class SymbolVisitor {
	private SemanticPass pass;
	alias pass this;
	
	alias SemanticPass.Step Step;
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	Symbol visit(Symbol s) {
		auto oldSymbol = symbol;
		scope(exit) symbol = oldSymbol;
		
		symbol = s;
		
		return this.dispatch(s);
	}
	
	// TODO: merge function delcaration and definition.
	Symbol visit(FunctionDeclaration d) {
		// XXX: May yield, but is only resolved within function, so everything depending on this declaration happen after.
		d.parameters = d.parameters.map!(p => pass.scheduler.register(p, this.dispatch(p), Step.Processed)).array();
		
		d.returnType = pass.visit(d.returnType);
		
		d.type = new FunctionType(d.location, d.linkage, d.returnType, d.parameters, d.isVariadic);
		
		// Update mangle prefix.
		auto oldManglePrefix = manglePrefix;
		scope(exit) manglePrefix = oldManglePrefix;
		
		manglePrefix = manglePrefix ~ to!string(d.name.length) ~ d.name;
		
		auto paramsToMangle = d.isStatic?d.parameters:d.parameters[1 .. $];
		switch(d.linkage) {
			case "D" :
				d.mangle = "_D" ~ manglePrefix ~ (d.isStatic?"F":"FM") ~ paramsToMangle.map!(p => (p.isReference?"K":"") ~ pass.typeMangler.visit(p.type)).join() ~ "Z" ~ typeMangler.visit(d.returnType);
				break;
			
			case "C" :
				d.mangle = d.name;
				break;
			
			default:
				assert(0, "Linkage " ~ d.linkage ~ " is not supported.");
		}
		
		scheduler.register(d, d, Step.Processed);
		
		return d;
	}
	
	Symbol visit(FunctionDefinition d) {
		// XXX: May yield, but is only resolved within function, so everything depending on this declaration happen after.
		d.parameters = d.parameters.map!(p => pass.scheduler.register(p, this.dispatch(p), Step.Processed)).array();
		
		// Update mangle prefix.
		auto oldManglePrefix = manglePrefix;
		scope(exit) manglePrefix = oldManglePrefix;
		
		manglePrefix = manglePrefix ~ to!string(d.name.length) ~ d.name;
		
		// Compute return type.
		if(typeid({ return d.returnType; }()) !is typeid(AutoType)) {
			d.returnType = pass.visit(d.returnType);
		}
		
		// Prepare statement visitor for return type.
		auto oldReturnType = returnType;
		scope(exit) returnType = oldReturnType;
		
		returnType = d.returnType;
		
		// If it isn't a static method, add this.
		// checking resolvedTypes Ensure that it isn't ran twice.
		if(!d.isStatic) {
			auto thisParameter = new Parameter(d.location, "this", thisType);
			thisParameter = pass.scheduler.register(thisParameter, this.dispatch(thisParameter), Step.Processed);
			thisParameter.isReference = true;
			
			d.parameters = thisParameter ~ d.parameters;
		}
		
		{
			// Update scope.
			auto oldScope = currentScope;
			scope(exit) currentScope = oldScope;
			
			currentScope = d.dscope;
			
			// And visit.
			// TODO: change ast to allow any statement as function body;
			d.fbody = cast(BlockStatement) pass.visit(d.fbody);
		}
		
		if(typeid({ return d.returnType; }()) is typeid(AutoType)) {
			// Should be useless once return type inference is properly implemented.
			if(typeid({ return pass.returnType; }()) is typeid(AutoType)) {
				assert(0, "can't infer return type");
			}
			
			d.returnType = returnType;
		}
		
		d.type = new FunctionType(d.location, d.linkage, d.returnType, d.parameters, d.isVariadic);
		
		auto paramsToMangle = d.isStatic?d.parameters:d.parameters[1 .. $];
		switch(d.linkage) {
			case "D" :
				d.mangle = "_D" ~ manglePrefix ~ (d.isStatic?"F":"FM") ~ paramsToMangle.map!(p => (p.isReference?"K":"") ~ pass.typeMangler.visit(p.type)).join() ~ "Z" ~ typeMangler.visit(d.returnType);
				break;
			
			case "C" :
				d.mangle = d.name;
				break;
			
			default:
				assert(0, "Linkage " ~ d.linkage ~ " is not supported.");
		}
		
		scheduler.register(d, d, Step.Processed);
		
		return d;
	}
	
	Parameter visit(Parameter d) {
		d.type = pass.visit(d.type);
		
		return d;
	}
	
	VariableDeclaration visit(VariableDeclaration d) {
		d.value = pass.visit(d.value);
		
		// If the type is infered, then we use the type of the value.
		if(cast(AutoType) d.type) {
			d.type = d.value.type;
		} else {
			d.type = pass.visit(d.type);
		}
		
		d.value = implicitCast(d.location, d.type, d.value);
		
		if(d.isEnum) {
			d.value = evaluate(d.value);
		}
		
		if(d.isStatic) {
			d.mangle = "_D" ~ manglePrefix ~ to!string(d.name.length) ~ d.name ~ typeMangler.visit(d.type);
		}
		
		scheduler.register(d, d, Step.Processed);
		
		return d;
	}
	
	Symbol visit(FieldDeclaration d) {
		// XXX: hacky !
		auto oldIsEnum = d.isEnum;
		scope(exit) d.isEnum = oldIsEnum;
		
		d.isEnum = true;
		
		return visit(cast(VariableDeclaration) d);
	}
	
	Symbol visit(StructDefinition d) {
		// Update mangle prefix.
		auto oldManglePrefix = manglePrefix;
		scope(exit) manglePrefix = oldManglePrefix;
		
		manglePrefix = manglePrefix ~ to!string(d.name.length) ~ d.name;
		
		d.mangle = "S" ~ manglePrefix;
		
		// Update scope.
		auto oldScope = currentScope;
		scope(exit) currentScope = oldScope;
		
		currentScope = d.dscope = new NestedScope(oldScope);
		
		auto oldThisType = thisType;
		scope(exit) thisType = oldThisType;
		
		thisType = new SymbolType(d.location, d);
		
		FieldDeclaration[] fields;
		Declaration[] otherMembers;
		uint fieldIndex;
		foreach(m; d.members) {
			if(auto var = cast(VariableDeclaration) m) {
				if(!var.isStatic) {
					auto f = new FieldDeclaration(var, fieldIndex++);
					currentScope.addSymbol(f);
					fields ~= f;
					
					continue;
				}
			}
			
			otherMembers ~= m;
		}
		
		auto otherSymbols = pass.visit(otherMembers);
		
		// Create .init
		fields = cast(FieldDeclaration[]) scheduler.schedule(fields, f => visit(f), Step.Processed);
		
		auto tuple = new TupleExpression(d.location, fields.map!(f => f.value).array());
		tuple.type = thisType;
		
		auto init = new VariableDeclaration(d.location, thisType, "init", tuple);
		init.isStatic = true;
		init.mangle = "_D" ~ manglePrefix ~ to!string(init.name.length) ~ init.name ~ d.mangle;
		
		d.dscope.addSymbol(init);
		scheduler.register(init, init, Step.Processed);
		
		scheduler.register(d, d, Step.Populated);
		
		// XXX: big lie :D
		scheduler.register(d, d, Step.Processed);
		
		d.members = cast(Declaration[]) fields ~ cast(Declaration[]) scheduler.schedule(otherSymbols, m => visit(m), Step.Processed) ~ init;
		
		return d;
	}
	
	Symbol visit(ClassDefinition d) {
		// Update mangle prefix.
		auto oldManglePrefix = manglePrefix;
		scope(exit) manglePrefix = oldManglePrefix;
		
		manglePrefix = manglePrefix ~ to!string(d.name.length) ~ d.name;
		
		d.mangle = "C" ~ manglePrefix;
		
		auto oldScope = currentScope;
		scope(exit) currentScope = oldScope;
		
		currentScope = d.dscope = new NestedScope(oldScope);
		
		auto oldThisType = thisType;
		scope(exit) thisType = oldThisType;
		
		thisType = new SymbolType(d.location, d);
		
		auto members = pass.visit(d.members);
		
		// XXX: Not quite right !
		scheduler.register(d, d, Step.Processed);
		
		d.members = cast(Declaration[]) scheduler.schedule(members, m => visit(m), Step.Processed);
		
		return d;
	}
	
	Symbol visit(EnumDeclaration d) {
		auto type = pass.visit(d.type);
		
		if(auto asEnum = cast(EnumType) type) {
			if(typeid({ return asEnum.type; }()) !is typeid(IntegerType)) {
				assert(0, "enum are of integer type.");
			}
		} else {
			assert(0, "enum must have an enum type !");
		}
		
		// Update mangle prefix.
		auto oldManglePrefix = manglePrefix;
		scope(exit) manglePrefix = oldManglePrefix;
		
		manglePrefix = manglePrefix ~ to!string(d.name.length) ~ d.name;
		
		d.mangle = "E" ~ manglePrefix;
		
		auto oldScope = currentScope;
		scope(exit) currentScope = oldScope;
		
		currentScope = d.dscope = new NestedScope(oldScope);
		
		// XXX: Big lie again !
		scheduler.register(d, d, Step.Processed);
		
		VariableDeclaration previous;
		foreach(e; d.enumEntries) {
			if(typeid({ return e.value; }()) is typeid(DefaultInitializer)) {
				if(previous) {
					e.value = new AddExpression(e.location, new SymbolExpression(e.location, previous), makeLiteral(e.location, 1));
				} else {
					e.value = makeLiteral(e.location, 0);
				}
			}
			
			e.value = explicitCast(e.location, type, pass.evaluate(pass.visit(e.value)));
			e.type = type;
			
			d.dscope.addSymbol(e);
			scheduler.register(e, e, Step.Processed);
			
			previous = e;
		}
			
		return d;
	}
	
	Symbol visit(AliasDeclaration d) {
		d.type = pass.visit(d.type);
		
		scheduler.register(d, d, Step.Processed);
		
		return d;
	}
	
	Symbol visit(TemplateDeclaration d) {
		d.mangle = manglePrefix;
		
		scheduler.register(d, d, Step.Processed);
		
		return d;
	}
}
