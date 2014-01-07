% note how init is handled for multiple chains
% https://groups.google.com/forum/?fromgroups#!searchin/stan-users/command$20line/stan-users/2YNalzIGgEs/NbbDsM9R9PMJ
% bash script for stan
% https://groups.google.com/forum/?fromgroups#!topic/stan-dev/awcXvXxIfHg



% TODO
% expose remaining pystan parameters
% inits
% update for Stan 2.1.0
% way to determined compiled status? checksum??? force first time compile?
% dump reader (to load data as struct)
% model definitions
%
classdef stan < handle
   properties(GetAccess = public, SetAccess = public)
      stan_home = '/Users/brian/Downloads/stan-2.0.1';
      working_dir
   end
   properties(GetAccess = public, SetAccess = private)
      model_home % url or path to .stan file
   end
   properties(GetAccess = public, SetAccess = public, Dependent = true)
      file
      model_name
      model_code
      
      id 
      iter %
      warmup
      thin
      seed      

      %algorithm
      init
      
      sample_file
      diagnostic_file
      refresh
   end
   properties(GetAccess = public, SetAccess = public)
      method
      data % need to handle matrix versus filename, should have a callback

      chains

      inc_warmup
      verbose
      file_overwrite = false;
   end 
   properties(GetAccess = public, SetAccess = private, Dependent = true)
      command
   end
   properties(GetAccess = public, SetAccess = public)      % eventually private
      params
      defaults
      validators
      
      file_
      model_name_
      %model_code_
   end
   properties(GetAccess = public, SetAccess = protected)
      version = '0.0.0';
   end

   methods
      %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
      %% Constructor      
      function self = stan(varargin)
         [self.defaults,self.validators] = self.stanParams();
         self.params = self.defaults;
         self.working_dir = pwd;

         p = inputParser;
         p.KeepUnmatched= true;
         p.FunctionName = 'stan constructor';
         p.addParamValue('stan_home',self.stan_home);
         p.addParamValue('file','');
         p.addParamValue('model_name','anon_model');
         p.addParamValue('model_code',{});
         p.addParamValue('working_dir',pwd);
         p.addParamValue('method','sample',@(x) validatestring(x,{'sample' 'optimize' 'diagnose'}));
         p.addParamValue('chains',4);
         p.addParamValue('inc_warmup',false);
         p.addParamValue('sample_file','',@ischar);
         p.addParamValue('refresh',self.defaults.output.refresh,@isnumeric);
         p.addParamValue('file_overwrite',false,@islogical);
         p.parse(varargin{:});

         self.file_overwrite = p.Results.file_overwrite;
         self.stan_home = p.Results.stan_home;
         self.file = p.Results.file;
         if isempty(self.file)
            self.model_name = p.Results.model_name;
         end
         self.model_code = p.Results.model_code;
         self.working_dir = p.Results.working_dir;
         
         self.method = p.Results.method;
         self.inc_warmup = p.Results.inc_warmup;
         self.chains = p.Results.chains;
         
         self.refresh = p.Results.refresh;
         if isempty(p.Results.sample_file)
            self.sample_file = self.params.output.file;
         else
            self.sample_file = p.Results.sample_file;
            self.params.output.file = self.sample_file;
         end
         
         % pass remaining inputs to set()
         self.set(p.Unmatched);
      end
      
      function set.stan_home(self,d)
         [~,fa] = fileattrib(d);
         if fa.directory
            if exist(fullfile(fa.Name,'makefile'),'file') && exist(fullfile(fa.Name,'bin'),'dir')
               self.stan_home = fa.Name;
            else
               error('stan:stan_home:InputFormat',...
                  'Does not look like a proper stan setup');
            end
         else
            error('stan:stan_home:InputFormat',...
               'stan_home must be the base directory for stan');
         end
      end
      
      function set.file(self,fname)
         if ischar(fname)
            self.update_model('file',fname);
         else
            error('stan:file:InputFormat','file must be a string');
         end
      end
            
      function file = get.file(self)
         file = self.file_;
      end
 
      function set.model_name(self,model_name)
         if ischar(model_name) && (numel(model_name)>0)
            if isempty(self.file)
               self.model_name_ = model_name;
            else
               self.update_model('model_name',model_name);
            end
            
         else
            error('stan:model_name:InputFormat',...
               'model_name should be a non-empty string');
         end
      end
            
      function model_name = get.model_name(self)
         model_name = self.model_name_;
      end
      
      function path = model_path(self)
         path = fullfile(self.model_home,[self.model_name '.stan']);
      end
      
      
%       function bool = isValid(self)
%       end
%       function bool = isCompiled(self)
%       end
      
      function set.model_code(self,model)
         if isempty(model)
            return;
         end
         if ischar(model)
            % Convert a char array into a cell array of strings split by line
            model = regexp(model,'(\r\n|\n|\r)','split')';
         end
         % FIXME , should deblank lines first for leading whitespace
         if any(strncmp('data',model,4)) || any(strncmp('parameters',model,10)) || any(strncmp('model',model,5))
            self.update_model('model_code',model);
         else
            error('does not look like a stan model');
         end
      end
      
      function model_code = get.model_code(self)
         if isempty(self.model_home)
            model_code = {};
            return;
         end
         % Always reread file? Or checksum? or listen for property change?
         model_code = read_lines(fullfile(self.model_home,self.file));
      end
      
      function set.model_home(self,d)
         if isempty(d)
            self.model_home = pwd;
         elseif isdir(d)
            [~,fa] = fileattrib(d);
            if fa.UserWrite && fa.UserExecute
               if ~strcmp(self.model_home,fa.Name)
                  fprintf('New model_home set.\n');
               end
               self.model_home = fa.Name;
            else
               error('Must be able to write and execute in model_home');
            end
         else
            error('model_home must be a directory');
         end
      end
      
      function set.working_dir(self,d)
         if isdir(d)
            [~,fa] = fileattrib(d);
            if fa.directory && fa.UserWrite && fa.UserRead
               self.working_dir = fa.Name;
            else
               self.working_dir = tempdir;
            end
         else
            error('working_dir must be a directory');
         end
      end
            
      function set.chains(self,nChains)
         if (nChains>java.lang.Runtime.getRuntime.availableProcessors) || (nChains<1)
            error('stan:chains:InputFormat','# of chains must be from 1 to # of cores.');
         end
         nChains = min(java.lang.Runtime.getRuntime.availableProcessors,max(1,round(nChains)));
         self.chains = nChains;
      end
      
      function set.refresh(self,refresh)
         % reasonable default?
         self.params.output.refresh = refresh;
      end
      
      function set.id(self,id)
         validateattributes(id,self.validators.id{1},self.validators.id{2})
         self.params.id = id;
      end
      
      function id = get.id(self)
         id = self.params.id;
      end
      
      function set.iter(self,iter)
         validateattributes(iter,self.validators.sample.num_samples{1},self.validators.sample.num_samples{2})
         self.params.sample.num_samples = iter;
      end
      
      function iter = get.iter(self)
         iter = self.params.sample.num_samples;
      end
      
      function set.warmup(self,warmup)
         validateattributes(warmup,self.validators.sample.num_warmup{1},self.validators.sample.num_warmup{2})
         self.params.sample.num_warmup = warmup;
      end
      
      function warmup = get.warmup(self)
         warmup = self.params.sample.num_warmup;
      end
      
      function set.thin(self,thin)
         validateattributes(thin,self.validators.sample.thin{1},self.validators.sample.thin{2})
         self.params.sample.thin = thin;
      end
      
      function thin = get.thin(self)
         thin = self.params.sample.thin;
      end
      
      function set.init(self,init)
         % handle vector case, looks like it will require writing to dump
         % file as well
         validateattributes(init,self.validators.init{1},self.validators.init{2})
         self.params.init = init;
      end
      
      function init = get.init(self)
         init = self.params.init;
      end
      
      function set.seed(self,seed)
         % handle chains > 1
         validateattributes(seed,self.validators.random.seed{1},self.validators.random.seed{2})
         if seed < 0
            self.params.random.seed = round(sum(100*clock));
         else
            self.params.random.seed = seed;
         end
      end
      
      function seed = get.seed(self)
         seed = self.params.random.seed;
      end
      
      function set.diagnostic_file(self,name)
         if ischar(name)
            self.params.output.diagnostic_file = name;
         end
      end
      
      function name = get.diagnostic_file(self)
         name = self.params.output.diagnostic_file;
      end
      
      function set.sample_file(self,name)
         if ischar(name)
            self.params.output.file = name;
         end
      end
      
      function name = get.sample_file(self)
         name = self.params.output.file;
      end
      
      function set.inc_warmup(self,bool)
         validateattributes(bool,self.validators.sample.save_warmup{1},self.validators.sample.save_warmup{2})
         self.params.sample.save_warmup = bool;
      end
      
      function bool = get.inc_warmup(self)
         bool = self.params.sample.save_warmup;
      end
      
      function set.data(self,d)
         if isstruct(d) || isa(d,'containers.Map')
            % how to contruct filename?
            fname = fullfile(self.working_dir,'temp.data.R');
            rdump(fname,d);
            self.data = d;
            self.params.data.file = fname;
         elseif ischar(d)
            if exist(d,'file')
               % TODO: read data into struct... what a mess...
               % self.data = dump2struct()
               self.data = 'from file';
               self.params.data.file = d;
            else
               error('data file not found');
            end
         else
            
         end
      end
      
      function set(self,varargin)
         p = inputParser;
         p.KeepUnmatched= false;
         p.FunctionName = 'stan parameter setter';
         p.addParamValue('id',self.id);
         p.addParamValue('iter',self.iter);
         p.addParamValue('warmup',self.warmup);
         p.addParamValue('thin',self.thin);
         p.addParamValue('init',self.init);
         p.addParamValue('seed',self.seed);
         p.addParamValue('chains',self.chains);
         p.addParamValue('data',[]);
         p.parse(varargin{:});

         self.id = p.Results.id;
         self.iter = p.Results.iter;
         self.warmup = p.Results.warmup;
         self.thin = p.Results.thin;
         self.init = p.Results.init;
         self.seed = p.Results.seed;
         self.chains = p.Results.chains;
         self.data = p.Results.data;
      end
      
      function command = get.command(self)
         % FIXME: add a prefix and postfix property according to os?
         command = {[fullfile(self.model_home,self.model_name) ' ']};
         str = parseParams(self.params,self.method);
         command = cat(1,command,str);
      end
      
      function fit = sampling(self,varargin)
         if nargout == 0
            error('stan:sampling:OutputFormat',...
               'Need to assign the fit to a variable');
         end
         
         self.set(varargin{:});
         self.method = 'sample';
         
         % FIXME, won't work on PC
         if ~exist(fullfile(self.model_home,self.model_name),'file')
            fprintf('We have to compile the model first...\n');
            self.compile('model');
         end
%            self.compile('model');
         
         fprintf('Stan is sampling with %g chains...\n',self.chains);
         
         chain_id = 1:self.chains;
         [~,name,ext] = fileparts(self.sample_file);
         base_name = self.sample_file;
         base_seed = self.seed;
         for i = 1:self.chains
            sample_file{i} = [name '-' num2str(chain_id(i)) ext];
            self.sample_file = sample_file{i};
            % Advance seed according to some rule
            self.seed = base_seed + chain_id(i); 
            % Fork process
            p(i) = processManager('id',sample_file{i},...
                               'command',sprintf('%s',self.command{:}),...
                               'workingDir',self.model_home,...
                               'wrap',100,...
                               'keepStdout',false,...
                               'pollInterval',1,...
                               'printStdout',true,...
                               'autoStart',false);
         end
         self.sample_file = base_name;
         self.seed = base_seed;
         %self.processes = p;

         if nargout == 1
            fit = stanFit('model',self,'processes',p,'sample_file',sample_file);
         end
         p.start();
      end
      
      function optimizing(self)
      end
      function diagnose(self)
      end
      
      function help(self,str)
         % TODO: 
         % if str is stanc or other basic binary
         
         %else
         % need to check that model binary exists
         command = [fullfile(self.model_home,self.model_name) ' ' str ' help'];
         p = processManager('id','stan help','command',command,...
                            'workingDir',self.model_home,...
                            'wrap',100,...
                            'keepStdout',true,...
                            'printStdout',false);
         p.block(0.05);
         if p.exitValue == 0
            % Trim off the boilerplate
            ind = find(strncmp('Usage: ',p.stdout,7));
            fprintf('%s\n',p.stdout{1:ind-1});
         else
            fprintf('%s\n',p.stdout{:});
         end
      end
      
      function compile(self,target)
         if nargin < 2
            target = 'model';
         end
         if any(strcmp({'stanc' 'libstan.a' 'libstanc.a' 'print'},target))
            command = ['make bin/' target];
            printStderr = false;
         elseif strcmp(target,'model')
            command = ['make ' fullfile(self.model_home,self.model_name)];
            printStderr = true;
         else
            error('Unknown target');
         end
         p = processManager('id','compile',...
                            'command',command,...
                            'workingDir',self.stan_home,...
                            'printStderr',printStderr,...
                            'keepStderr',true,...
                            'keepStdout',true);
         p.block(0.05);
      end
      
%       function disp(self)
% 
%       end
   end
   
   methods(Access = private)
      function update_model(self,flag,arg)
      % Model must exist with extension .stan, but compiling
      % requires passing the name without extension
      %
      % Pystan,
      % There are three ways to specify the model's code for `stan_model`.
      % 
      %     1. parameter `model_code`, containing a string to whose value is
      %        the Stan model specification,
      % 
      %     2. parameter `file`, indicating a file (or a connection) from
      %        which to read the Stan model specification, or
      % 
      %     3. parameter `stanc_ret`, indicating the re-use of a model
      %          generated in a previous call to `stanc`.
      %
      % in stan object, model is defined by three attributes,
      %   1) a name
      %   2) a file on disk (or url)
      %   3) code
      % 1) does not include the .stan extension, and should always match the 
      % name of the file (2, sans extension). 3) is always read directly from
      % 2). This means, when either 1) or 2) change, we have to update 2) and 
      % 1), respectively.
      % Changing the model_name
      %    write a new file matching model_name (check overwrite)
      % Changing the file
      %    set file, model_name, model_home
      % Changing the code
      %    write a new file matching model_name (check overwrite)
         if nargin == 3
            if isempty(arg)
               return;
            end
         end

         switch lower(flag)
            case {'model_name'}
               [~,name,ext] = fileparts(arg);
               if isempty(self.model_code)
                  % no code, model not defined
                  self.model_name_ = name;
               else
                  % have code
                  self.model_name_ = name;
                  self.update_model('write',self.model_code);
               end
            case {'file'}
               [path,name,ext] = fileparts(arg);
               if ~strcmp(ext,'.stan')
                  error('include extension');
               end
               if ~((exist([name ext],'file')==2) || strncmp(path,'http',4))
                  error('file does not exist');
               end
               self.file_ = [name ext];
               self.model_name_ = name;
               self.model_home = path;
            case {'model_code'}
               % model name exists (default anon)
               % model home exists
               self.update_model('write',arg);
            case {'write'}
               if isempty(self.model_home)
                  self.model_home = self.working_dir;
               end
               fname = fullfile(self.model_home,[self.model_name '.stan']);
               if exist(fname,'file') == 2
                  % Model file already exists
                  if self.file_overwrite
                     write_lines(fname,arg);
                     self.update_model('file',fname);
                  else
                     [filename,filepath] = uiputfile('*.stan','Name stan model');
                     [~,name] = fileparts(filename);
                     self.model_name_ = name;
                     self.model_home = filepath;
                     write_lines(fullfile(self.model_home,[self.model_name '.stan']),arg);
                     self.update_model('file',fullfile(self.model_home,[self.model_name '.stan']));
                  end
               else
                  write_lines(fname,arg);
                  self.update_model('file',fname);
               end
            otherwise
               error('');
         end
      end
   end

   methods(Static)
      function [params,valid] = stanParams()
         % Default Stan parameters and validators. Should only contain
         % parameters that are valid inputs to Stan cmd-line!
         % validator can be
         % 1) function handle
         % 2) 1x2 cell array of cells, input to validateattributes first element is classes,
         % second is attributes
         % 3) cell array of strings representing valid arguments
         params.sample = struct(...
                               'num_samples',1000,...
                               'num_warmup',1000,...
                               'save_warmup',false,...
                               'thin',1,...
                               'adapt',struct(...
                                              'engaged',true,...
                                              'gamma',0.05,...
                                              'delta',0.65,...
                                              'kappa',0.75,...
                                              't0',10),...
                               'algorithm','hmc',...
                               'hmc',struct(...
                                            'engine','nuts',...
                                            'static',struct('int_time',2*pi),...
                                            'nuts',struct('max_depth',10),...
                                            'metric','diag_e',...
                                            'stepsize',1,...
                                            'stepsize_jitter',0));
         valid.sample = struct(...
                               'num_samples',{{{'numeric'} {'scalar','>=',0}}},...
                               'num_warmup',{{{'numeric'} {'scalar','>=',0}}},...
                               'save_warmup',{{{'logical'} {'scalar'}}},...
                               'thin',{{{'numeric'} {'scalar','>',0}}},...
                               'adapt',struct(...
                                              'engaged',{{{'logical'} {'scalar'}}},...
                                              'gamma',{{{'numeric'} {'scalar','>',0}}},...
                                              'delta',{{{'numeric'} {'scalar','>',0}}},...
                                              'kappa',{{{'numeric'} {'scalar','>',0}}},...
                                              't0',{{{'numeric'} {'scalar','>',0}}}),...
                               'algorithm',{{'hmc'}},...
                               'hmc',struct(...
                                            'engine',{{'static' 'nuts'}},...
                                            'static',struct('int_time',{{{'numeric'} {'scalar','>',0}}}),...
                                            'nuts',struct('max_depth',{{{'numeric'} {'scalar','>',0}}}),...
                                            'metric',{{'unit_e' 'diag_e' 'dense_e'}},...
                                            'stepsize',1,...
                                            'stepsize_jitter',0));

         params.optimize = struct(...
                                 'algorithm','bfgs',...
                                 'nesterov',struct(...
                                                   'stepsize',1),...
                                 'bfgs',struct(...
                                               'init_alpha',0.001,...
                                               'tol_obj',1e-8,...
                                               'tol_grad',1e-8,...
                                               'tol_param',1e-8),...
                                 'iter',2000,...
                                 'save_iterations',false);

         valid.optimize = struct(...
                                 'algorithm',{{'nesterov' 'bfgs' 'newton'}},...
                                 'nesterov',struct(...
                                                   'stepsize',{{{'numeric'} {'scalar','>',0}}}),...
                                 'bfgs',struct(...
                                               'init_alpha',{{{'numeric'} {'scalar','>',0}}},...
                                               'tol_obj',{{{'numeric'} {'scalar','>',0}}},...
                                               'tol_grad',{{{'numeric'} {'scalar','>',0}}},...
                                               'tol_param',{{{'numeric'} {'scalar','>',0}}}),...
                                 'iter',{{{'numeric'} {'scalar','>',0}}},...
                                 'save_iterations',{{{'logical'} {'scalar'}}});

         params.diagnose = struct(...
                                 'test','gradient');
         valid.diagnose = struct(...
                                 'test',{{{'gradient'}}});

         params.id = 1; % 0 doesnot work as default
         valid.id = {{'numeric'} {'scalar','>',0}};
         params.data = struct('file','');
         valid.data = struct('file',@isstr);
         params.init = 2;
         valid.init = {{'numeric' 'char'} {'nonempty'}}; % shitty validator
         params.random = struct('seed',-1);
         valid.random = struct('seed',{{{'numeric'} {'scalar'}}});

         params.output = struct(...
                                'file','samples.csv',...
                                'append_sample',false,...
                                'diagnostic_file','',...
                                'append_diagnostic',false,...
                                'refresh',100);
         valid.output = struct(...
                                'file',@isstr,...
                                'append_sample',{{{'logical'} {'scalar'}}},...
                                'diagnostic_file',@isstr,...
                                'append_diagnostic',{{{'logical'} {'scalar'}}},...
                                'refresh',{{{'numeric'} {'scalar','>',0}}});
      end
   end
end

function count = write_lines(filename,contents)
   fid = fopen(filename,'w');
   if fid ~= -1
      count = fprintf(fid,'%s\n',contents{1:end-1});
      count2 = fprintf(fid,'%s',contents{end});
      count = count + count2;
      fclose(fid);
   else
      error('Cannot open file to write');
   end
end

function lines = read_lines(filename)
   try
      if strncmp(filename,'http',4)
         str = urlread(filename);
      else
         str = urlread(['file:///' filename]);
      end
      lines = regexp(str,'(\r\n|\n|\r)','split')';
   catch err
      if strcmp(err.identifier,'MATLAB:urlread:ConnectionFailed')
         %fprintf('File does not exist\n');
         lines = {};
      else
         rethrow(err);
      end
   end
end

% https://github.com/stan-dev/rstan/search?q=stan_rdump&ref=cmdform
% struct or containers.Map
function fid = rdump(fname,content)
   if isstruct(content)
      vars = fieldnames(content);
      data = struct2cell(content);
   elseif isa(content,'containers.Map')
      vars = content.keys;
      data = content.values;
   end

   fid = fopen(fname,'wt');
   for i = 1:numel(vars)
      if isscalar(data{i})
         fprintf(fid,'%s <- %d\n',vars{i},data{i});
      elseif isvector(data{i})
         fprintf(fid,'%s <- c(',vars{i});
         fprintf(fid,'%d, ',data{i}(1:end-1));
         fprintf(fid,'%d)\n',data{i}(end));
      elseif ismatrix(data{i})
         fprintf(fid,'%s <- structure(c(',vars{i});
         fprintf(fid,'%d, ',data{i}(1:end-1));
         fprintf(fid,'%d), .Dim = c(',data{i}(end));
         fprintf(fid,'%g,',size(data{i},1));
         fprintf(fid,'%g',size(data{i},2));
         fprintf(fid,'))\n')
      end
   end
   fclose(fid);
end

% Generate command string from parameter structure. Very inefficient...
% root = 'sample' 'optimize' or 'diagnose'
% return a containers.Map?
function str = parseParams(s,root)
   branch = {'sample' 'optimize' 'diagnose' 'static' 'nuts' 'nesterov' 'bfgs'};
   if nargin == 2
      branch = branch(~strcmp(branch,root));
      fn = fieldnames(s);
      d = intersect(fn,branch);
      s = rmfield(s,d);
   end

   fn = fieldnames(s);
   val = '';
   str = {};
   for i = 1:numel(fn)
      try
         if isstruct(s.(fn{i}))
            % If any of the fieldnames match the *previous* value, assume the
            % previous value is a selector from amongst the fielnames, and
            % delete the other branches
            if any(strcmp(fieldnames(s),val))
               root = val;
               branch = branch(~strcmp(branch,root));
               d = intersect(fieldnames(s),branch);
               s = rmfield(s,d);

               str2 = parseParams(s.(root));
               s = rmfield(s,root);
               str = cat(1,str,str2);
            else
               if ~strcmp(fn{i},val)
                  str = cat(1,str,{sprintf('%s ',fn{i})});
                  %fprintf('%s \\\n',fn{i});
               end
               str2 = parseParams(s.(fn{i}));
               str = cat(1,str,str2);
            end
         else
            val = s.(fn{i});
            if isnumeric(val) || islogical(val)
               val = num2str(val);
            end
            str = cat(1,str,{sprintf('%s=%s ',fn{i},val)});
            %fprintf('%s=%s \\\n',fn{i},val);
         end
      catch
         % We trimmed a branch,
         %fprintf('dropping\n')
      end
   end
end
