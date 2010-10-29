# Module, welches AccesRules fuer Controller/Actions und
# Model-Object umsetzt.
#
# Die Regeln werden aus der Datei "config/acces_rules.rb" geladen
#
# Author: Bernd Ledig
#

require 'singleton'

module Tuersteher

  # Logger to log messages with timestamp and severity
  class TLogger < Logger
    @@logger = nil

    def format_message(severity, timestamp, progname, msg)
      "#{timestamp.to_formatted_s(:db)} #{severity} #{msg}\n"
    end

    def self.logger
      return @@logger if @@logger
      @@logger = self.new(File.join(Rails.root, 'log', 'tuersteher.log'), 3)
      @@logger.level = INFO if Rails.env != 'development'
      @@logger
    end

    def self.logger= logger
      @@logger = logger
    end
  end


  class AccessRulesStorage
    include Singleton

    attr_accessor :rules_config_file # to set own access_rules-path

    DEFAULT_RULES_CONFIG_FILE = 'access_rules.rb' # in config-dir

    # private initializer why this class is a singleton
    def initialize
      @path_rules = []
      @model_rules = []
    end

    # get all path_rules as array of PathAccessRule-Instances
    def path_rules
      read_rules unless @was_read
      @path_rules
    end

    # get all model_rules as array of ModelAccessRule-Instances
    def model_rules
      read_rules unless @was_read
      @model_rules
    end


    # evaluated rules_definitions and create path-/model-rules
    def eval_rules rules_definitions
      @path_rules = []
      @model_rules = []
      eval rules_definitions, binding, (@rules_config_file||'no file')
      @was_read = true
      Tuersteher::TLogger.logger.info "Tuersteher::AccessRulesStorage: #{@path_rules.size} path-rules and #{@model_rules.size} model-rules"
    end

    # Load AccesRules from file
    #  config/access_rules.rb
    def read_rules
      @rules_config_file ||= File.join(Rails.root, 'config', DEFAULT_RULES_CONFIG_FILE)
      rules_file = File.new @rules_config_file
      @was_read = false
      content = nil
      if @last_mtime.nil? || rules_file.mtime > @last_mtime
        @last_mtime = rules_file.mtime
        content = rules_file.read
      end
      rules_file.close
      if content
        eval_rules content
      end
    rescue => ex
      Tuersteher::TLogger.logger.error "Tuersteher::AccessRulesStorage - Error in rules: #{ex.message}\n\t"+ex.backtrace.join("\n\t")
    end

    # definiert HTTP-Pfad-basierende Zugriffsregel
    #
    # path:            :all fuer beliebig, sonst String mit der http-path beginnen muss,
    #                  wird als RegEX-Ausdruck ausgewertet
    def path url_path
      if block_given?
        @current_rule_class = PathAccessRule
        @current_rule_init = url_path
        @current_rule_storage = @path_rules
        yield
        @current_rule_class = @current_rule_init = nil
      else
        rule = PathAccessRule.new(url_path)
        @path_rules << rule
        rule
      end
    end

    
    # definiert Model-basierende Zugriffsregel
    #
    # model_class:  Model-Klassenname oder :all fuer alle
    def model model_class
      if block_given?
        @current_rule_class = ModelAccessRule
        @current_rule_init = model_class
        @current_rule_storage = @model_rules
        yield
        @current_rule_class = @current_rule_init = @current_rule_storage = nil
      else
        rule = ModelAccessRule.new(model_class)
        @model_rules << rule
        rule
      end
    end

    # create new rule as grant-rule
    # and add this to the model_rules array
    def grant
      rule = @current_rule_class.new(@current_rule_init)
      @current_rule_storage << rule
      rule.grant
    end

    # create new rule as deny-rule
    # and add this to the model_rules array
    def deny
      rule = grant
      rule.deny
    end

    # Erweitern des Path um einen Prefix
    # Ist notwenig wenn z.B. die Rails-Anwendung nicht als root-Anwendung läuft
    # also root_path != '/' ist.'
    def extend_path_rules_with_prefix prefix
      Tuersteher::TLogger.logger.info "extend_path_rules_with_prefix: #{prefix}"
      @path_prefix = prefix
      path_rules.each do |rule|
        rule.path = "#{prefix}#{rule.path}" unless rule.path == :all
      end
    end


  end # of AccessRulesStorage


  class AccessRules
    class << self

      # Pruefen Zugriff fuer eine Web-action
      # user        User, für den der Zugriff geprüft werden soll (muss Methode has_role? haben)
      # path        Pfad der Webresource (String)
      # method      http-Methode (:get, :put, :delete, :post), default ist :get
      #
      def path_access?(user, path, method = :get)
        rule = AccessRulesStorage.instance.path_rules.detect do |r|
          r.fired?(path, method, user)
        end
        if Tuersteher::TLogger.logger.debug?
          if rule.nil?
            s = 'denied'
          elsif rule.deny?
            s = "denied with #{rule}"
          else
            s = "granted with #{rule}"
          end
          usr_id = user && user.respond_to?(:id) ? user.id : user.object_id
          Tuersteher::TLogger.logger.debug("Tuersteher: path_access?(user.id=#{usr_id}, path=#{path}, method=#{method})  =>  #{s}")
        end
        !(rule.nil? || rule.deny?)
      end


      # Pruefen Zugriff auf ein Model-Object
      #
      # user        User, für den der Zugriff geprüft werden soll (muss Methode has_role? haben)
      # model       das Model-Object
      # permission  das geforderte Zugriffsrecht (:create, :update, :destroy, :get)
      #
      # liefert true/false
      def model_access? user, model, permission
        raise "Wrong call! Use: model_access(model-instance-or-class, permission)" unless permission.is_a? Symbol
        return false unless model

        rule = AccessRulesStorage.instance.model_rules.detect do |rule|
          rule.fired? model, permission, user
        end
        access = rule && !rule.deny?
        if Tuersteher::TLogger.logger.debug?
          usr_id = user && user.respond_to?(:id) ? user.id : user.object_id
          if model.instance_of?(Class)
            Tuersteher::TLogger.logger.debug(
              "Tuersteher: model_access?(user.id=#{usr_id}, model=#{model}, permission=#{permission}) =>  #{access || 'denied'} #{rule}")
          else
            Tuersteher::TLogger.logger.debug(
              "Tuersteher: model_access?(user.id=#{usr_id}, model=#{model.class}(#{model.respond_to?(:id) ? model.id : model.object_id }), permission=#{permission}) =>  #{access || 'denied'} #{rule}")
          end
        end
        access
      end

      # Bereinigen (entfernen) aller Objecte aus der angebenen Collection,
      # wo der angegebene User nicht das angegebene Recht hat
      #
      # liefert ein neues Array mit den Objecten, wo der spez. Zugriff arlaubt ist
      def purge_collection user, collection, permission
        collection.select{|model| model_access?(user, model, permission)}
      end
    end # of Class-Methods
  end # of AccessRules



  # Module zum Include in Controllers
  # Dieser muss die folgenden Methoden bereitstellen:
  #
  #   current_user : akt. Login-User
  #   access_denied :  Methode aus dem authenticated_system, welche ein redirect zum login auslöst
  #
  # Der Loginuser muss fuer die hier benoetigte Funktionalitaet
  # die Methode:
  #   has_role?(role)  # role the Name of the Role as Symbol
  # besitzen.
  #
  # Beispiel der Einbindung in den ApplicationController
  #   include Tuersteher::ControllerExtensions
  #   before_filter :check_access # methode is from Tuersteher::ControllerExtensions
  #
  module ControllerExtensions

    @@url_path_method = nil
    @@prefix_checked = nil

    # Pruefen Zugriff fuer eine Web-action
    #
    # path        Pfad der Webresource (String)
    # method      http-Methode (:get, :put, :delete, :post), default ist :get
    #
    def path_access?(path, method = :get)
      unless @@prefix_checked
        @@prefix_checked = true
        prefix = respond_to?(:root_path) && root_path
        if prefix.size > 1
          AccessRulesStorage.instance.extend_path_rules_with_prefix(prefix)
          Rails.logger.info "Tuersteher::ControllerExtensions: set path-prefix to: #{prefix}"
        end
      end
      AccessRules.path_access? current_user, path, method
    end

    # Pruefen Zugriff auf ein Model-Object
    #
    # model       das Model-Object
    # permission  das geforderte Zugriffsrecht (:create, :update, :destroy, :get)
    #
    # liefert true/false
    def model_access? model, permission
      AccessRules.model_access? current_user, model, permission
    end

    # Bereinigen (entfernen) aller Objecte aus der angebenen Collection,
    # wo der akt. User nicht das angegebene Recht hat
    #
    # liefert ein neues Array mit den Objecten, wo der spez. Zugriff arlaubt ist
    def purge_collection collection, permission
      AccessRules.purge_collection(current_user, collection, permission)
    end


    def self.included(base)
      base.class_eval do
        # Diese Methoden  auch als Helper fuer die Views bereitstellen
        helper_method :path_access?, :model_access?, :purge_collection
      end
    end

    protected

    # Pruefen, ob Zugriff des current_user
    # fuer aktullen Request erlaubt ist
    def check_access

      # im dev-mode rules bei jeden request auf Änderungen prüfen
      AccessRulesStorage.instance.read_rules if Rails.env=='development'

      # Rails3 hat andere url-path-methode
      @@url_path_method ||= Rails.version[0..1]=='3.' ? :fullpath : :request_uri

      # bind current_user on the current thread
      Thread.current[:user] = current_user

      req_method = request.method
      req_method = req_method.downcase.to_sym if req_method.is_a?(String)
      url_path = request.send(@@url_path_method)
      unless path_access?(url_path, req_method)
        usr_id = current_user && current_user.respond_to?(:id) ? current_user.id : current_user.object_id
        msg = "Tuersteher#check_access: access denied for #{request.request_uri} :#{req_method} user.id=#{usr_id}"
        Tuersteher::TLogger.logger.warn msg
        logger.warn msg  # log message also for Rails-Default logger
        access_denied  # Methode aus dem authenticated_system, welche ein redirect zum login auslöst
      end
    end

  end



  # Module for include in Model-Object-Classes
  #
  # The module get the current-user from Thread.current[:user]
  #
  # Sample for ActiveRecord-Class
  #   class Sample < ActiveRecord::Base
  #    include Tuersteher::ModelExtensions
  #
  #     def transfer_to account
  #       check_model_access :transfer # raise a exception if not allowed
  #       ....
  #     end
  #
  #
  module ModelExtensions

    # Check permission for the Model-Object
    #
    # permission  the requested permission (sample :create, :update, :destroy, :get)
    #
    # raise a SecurityError-Exception if access denied
    def check_access permission
      user = Thread.current[:user]
      unless AccessRules.model_access? user, self, permission
        raise SecurityError, "Access denied! Current user have no permission '#{permission}' on Model-Object #{self}."
      end
    end

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods

      # Bereinigen (entfernen) aller Objecte aus der angebenen Collection,
      # wo der akt. User nicht das angegebene Recht hat
      #
      # liefert ein neues Array mit den Objecten, wo der spez. Zugriff arlaubt ist
      def purge_collection collection, permission
        user = Thread.current[:user]
        AccessRules.purge_collection(user, collection, permission)
      end
    end # of ClassMethods

  end # of module ModelExtensions



  # Astracte base class for Access-Rules
  class BaseAccessRule

    def initialize
      @roles = []
      @access_method = :all
    end

    # add role
    def role(role_name)
      raise "wrong role '#{role_name}'! Must be a symbol " unless role_name.is_a?(Symbol)
      @roles << role_name
      self
    end

    # add list of roles
    def roles(*role_names)
      role_names.flatten.each{|role_name| role(role_name)}
      self
    end

    # add extension-definition
    # parmaters:
    #   method_name:      Symbol with the name of the method to call for addional check
    #   expected_value:   optional expected value for the result of the with metho_name specified method, defalt is true
    def extension method_name, expected_value=nil
      @check_extensions ||= {}
      @check_extensions[method_name] = expected_value
      self
    end

    # mark this rule as grant-rule
    def grant
      self
    end

    # mark this rule as deny-rule
    def deny
      @deny = true
      self
    end

    # is this rule a deny-rule
    def deny?
      @deny
    end

    # set methode for access
    # access_method        Name of Methode for access as Symbol
    def method(access_method)
      @access_method = access_method
      self
    end

    # negate role-membership
    def not
      @not = true
      self
    end

    protected

    # check, if this rule granted for specified user
    def grant_role? user
      return true if @roles.empty?
      return false if user.nil?
      role = @roles.detect{|r| user.has_role?(r)}
      role = !role if @not
      return true if role
      false
    end

    def grant_access_method? method
      return true if @access_method==:all
      @access_method == method
    end

  end # of BaseAccessRule


  class PathAccessRule < BaseAccessRule

    METHOD_NAMES = [:get, :edit, :put, :delete, :post, :all].freeze
    attr_reader :path

    # Zugriffsregel
    #
    # path          :all fuer beliebig, sonst String mit der http-path beginnen muss
    #
    def initialize(path)
      raise "wrong path '#{path}'! Must be a String or :all ." unless path==:all or path.is_a?(String)
      super()
      self.path = path
    end

    def path= url_path
      @path = url_path
      if url_path != :all
        # path in regex ^#{path} wandeln ausser bei "/",
        # dies darf keine Regex mit ^/ werden,
        # da diese ja immer matchen wuerde
        if url_path == "/"
          @path_regex = /^\/$/
        else
          @path_regex = /^#{url_path}/
        end
      end
    end

    # set http-methode
    # http_method        http-Method, allowed is :get, :put, :delete, :post, :all
    def method(http_method)
      raise "wrong method '#{http_method}'! Must be #{METHOD_NAMES.join(', ')} !" unless METHOD_NAMES.include?(http_method)
      super
      self
    end



    # pruefen, ob Zugriff fuer angegebenen
    # path / method fuer den current_user erlaubt ist
    #
    # user ist ein Object (meist der Loginuser),
    # welcher die Methode 'has_role?(role)' besitzen muss.
    # *roles ist dabei eine Array aus Symbolen
    #
    def fired?(path, method, user)
      user = nil if user==:false # manche Authenticate-System setzen den user auf :false

      if @path!=:all && !(@path_regex =~ path)
        return false
      end

      return false unless grant_access_method?(method)
      return false unless grant_role?(user)
      return false unless grant_extension?(user)

      true
    end


    def to_s
      s = "PathAccesRule[#{@deny ? 'DENY ' : ''}#{@path}, #{@access_method}, #{@roles.join(' ')}"
      s << " #{@check_extensions.inspect}" if @check_extensions
      s << ']'
      s
    end

    private

    # check, if this rule grant the defined extension (if exist)
    def grant_extension? user
      return true if @check_extensions.nil?
      return false if user.nil?  # check_extensions need a user
      @check_extensions.each do |key, value|
        unless user.respond_to?(key)
          Tuersteher::TLogger.logger.warn("#{to_s}.fired? => false why user have not check-extension method '#{key}'!")
          return false
        end
        if value
          return false unless user.send(key,value)
        else
          return false unless user.send(key)
        end
      end
      true
    end

  end



  class ModelAccessRule < BaseAccessRule

    # erzeugt neue Object-Zugriffsregel
    #
    # clazz         Model-Klassenname oder :all fuer alle
    # access_type   Zugriffsart (:create, :update, :destroy, :all o.A. selbst definierte Typem)
    # roles         Aufzählung der erforderliche Rolen (:all für ist egal),
    #               hier ist auch ein Array von Symbolen möglich
    # block         optionaler Block, wird mit model und user aufgerufen und muss true oder false liefern
    #               hier ein Beispiel mit Block:
    #               <code>
    #                 # Regel, in der sich jeder User selbst aendern darf
    #                 ModelAccessRule.new(User, :update, :all){|model,user| model.id==user.id}
    #               </code>
    #
    def initialize(clazz)
      raise "wrong clazz '#{clazz}'! Must be a Class or :all ." unless clazz==:all or clazz.is_a?(Class)
      super()
      @clazz = clazz.instance_of?(Symbol) ? clazz : clazz.to_s
    end


    # liefert true, wenn zugriff fuer das angegebene model mit
    # der Zugriffsart perm für das security_object hat
    #
    # model des zupruefende ModelObject
    # perm gewunschte Zugriffsart (Symbol :create, :update, :destroy)
    #
    # user ist ein User-Object (meist der Loginuser),
    # welcher die Methode 'has_role?(*roles)' besitzen muss.
    # *roles ist dabei eine Array aus Symbolen
    #
    #
    def fired? model, access_method, user
      user = nil if user==:false # manche Authenticate-System setzen den user auf :false
      m_class = model.instance_of?(Class) ? model : model.class
      if @clazz!=m_class.to_s && @clazz!=:all
        #Tuersteher::TLogger.logger.debug("#{to_s}.has_access? => false why #{@clazz}!=#{model.class.to_s} && #{@clazz}!=:all")
        return false
      end

      return false unless grant_access_method?(access_method)
      return false unless grant_role?(user)
      return false unless grant_extension?(user, model)
      true
    end

    def to_s
      s = "ModelAccessRule[#{@deny ? 'DENY ' : ''}#{@clazz}, #{@access_method}, #{@roles.join(' ')}"
      s << " #{@check_extensions.inspect}" if @check_extensions
      s << ']'
      s
    end

    private

    # check, if this rule grant the defined extension (if exist)
    def grant_extension? user, model
      return true if @check_extensions.nil?
      return false if model.nil?  # check_extensions need a model
      return false if model.instance_of?(Class) # no Extension-Call if model is a Class-Instance
      @check_extensions.each do |key, value|
        unless model.respond_to?(key)
          Tuersteher::TLogger.logger.warn("#{to_s}.fired? => false why model-onject have not check-extension method '#{key}'!")
          return false
        end
        if value
          return false unless model.send(key,user,value)
        else
          return false unless model.send(key,user)
        end
      end
      true
    end

  end

end
